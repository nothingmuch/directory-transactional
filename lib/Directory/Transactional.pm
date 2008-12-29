#!/usr/bin/perl
# ABSTRACT: ACID transactions on a directory tree

package Directory::Transactional;
use Squirrel;

use Set::Object;

use Carp;
use Fcntl qw(LOCK_EX LOCK_SH LOCK_NB);

use File::Spec;
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use File::Copy;
use IO::Dir;

use Directory::Transactional::TXN::Root;
use Directory::Transactional::TXN::Nested;

use namespace::clean -except => 'meta';

has root => (
	is  => "ro",
	required => 1,
);

has [qw(_root _work _backups _txns _locks)] => (
	isa => "Str",
	is  => "ro",
	lazy_build => 1,
);

sub _build__root    { my $self = shift; blessed($self->root) ? $self->root->stringify : $self->root }
sub _build__work    { File::Spec->catdir(shift->_root, ".txn_work_dir") } # top level for all temp files
sub _build__txns    { File::Spec->catdir(shift->_work, "txns") } # one subdir per transaction, used for temporary files when transactions are active
sub _build__backups { File::Spec->catdir(shift->_work, "backups") } # one subdir per transaction, used during commit to root
sub _build__locks   { File::Spec->catdir(shift->_work, "locks") } # shared between all workers, directory for lockfiles

has nfs => (
	isa => "Bool",
	is  => "ro",
	default => 0,
);

has global_lock => (
	isa => "Bool",
	is  => "ro",
	lazy => 1,
	default => sub { shift->nfs },
);

sub _get_lock {
	my ( $self, @args ) = @_;

	return $self->nfs ? $self->_get_nfslock(@args) : $self->_get_flock(@args);
}

# slow, portable locking
# relies on atomic link()
# on OSX the stress test gets race conditions
sub _get_nfslock {
	my ( $self, $file, $mode ) = @_;

	require File::NFSLock;
	if ( my $lock = File::NFSLock->new({
			file      => $file,
			lock_type => $mode,
		}) ) {
		return $lock;
	} elsif ( not($mode & LOCK_NB) ) {
		no warnings 'once';
		die $File::NFSLock::errstr;
	}

	return;
}

# much faster locking, doesn't work on NFS though
sub _get_flock {
	my ( $self, $file, $mode ) = @_;

	# create the parent directory for the lock if necessary
	# (the lock dir is cleaned on destruction)
	my ( $vol, $dir ) = File::Spec->splitpath($file);
	my $parent = File::Spec->catpath($vol, $dir, '');
	make_path($parent) unless -d $parent;

	# open the lockfile, creating if necessary
	open my $fh, "+>", $file or die $!;

	if ( flock($fh, $mode) ) {
		bless $fh, $mode & LOCK_EX ? "Directory::Transactional::Lock::Exclusive" : "Directory::Transactional::Lock::Shared";
		return $fh;
	} elsif ( not $!{EWOULDBLOCK} ) {
		# die on any error except failing to obtain a nonblocking lock
		die $!;
	} else {
		return;
	}
}

# support methods for fine grained locking
{
	package Directory::Transactional::Lock;

	sub unlock { close $_[0] }

	package Directory::Transactional::Lock::Exclusive;
	use Fcntl qw(LOCK_SH);

	our @ISA = qw(Directory::Transactional::Lock);

	sub is_shared { 0 }
	sub upgrade { }
	sub downgrade { flock($_[0], LOCK_SH) or die $! }

	package Directory::Transactional::Lock::Shared;
	use Fcntl qw(LOCK_EX);

	our @ISA = qw(Directory::Transactional::Lock);

	sub is_shared { 1 }
	sub upgrade { flock($_[0], LOCK_EX) or die $! }
	sub downgrade { }
}

# this is the current active TXN (head of transaction stack)
has _txn => (
	isa => "Directory::Transactional::TXN",
	is  => "rw",
	clearer => "_clear_txn",
);

has [qw(_txn_lock_file _shared_lock_file)] => (
	isa => "Str",
	is  => "ro",
	lazy_build => 1,
);

sub _build__txn_lock_file { File::Spec->catfile(shift->_work, "txn_lock") }
sub _build__shared_lock_file { shift->_work . ".lock" }

has _shared_lock => (
	is  => "ro",
	lazy_build => 1,
);

# the shared lock is always taken at startup
# a nonblocking attempt to lock it exclusively is made first, and if granted we
# have exclusive access to the work directory so recovery is run if necessary
sub _build__shared_lock {
	my $self = shift;

	my $file = $self->_shared_lock_file;

	if ( my $ex_lock = $self->_get_lock( $file, LOCK_EX|LOCK_NB ) ) {
		$self->recover;

		undef $ex_lock;
	}

	$self->_get_lock($file, LOCK_SH);
}

sub BUILD {
	my $self = shift;

	croak "If 'nfs' is set then so must be 'global_lock'"
		if $self->nfs and !$self->global_lock;

	# obtains the shared lock, running recovery if needed
	$self->_shared_lock;

	make_path($self->_work);
}

sub DEMOLISH {
	my $self = shift;

	# rollback any open txns
	while ( $self->_txn ) {
		$self->txn_rollback;
	}

	# lose the shared lock
	$self->_clear_shared_lock;

	# cleanup workdirs
	# only remove if no other workers are active, so that there is no race
	# condition in their directory creation code
	if ( my $ex_lock = $self->_get_lock( $self->_shared_lock_file, LOCK_EX|LOCK_NB ) ) {
		# we don't really care if there's an error
		remove_tree($self->_locks);
		rmdir $self->_work;
		rmdir $self->_txns;
		rmdir $self->_backups;
		CORE::unlink $self->_txn_lock_file;

		rmdir $self->_work;

		CORE::unlink $self->_shared_lock_file;
	}
}

sub recover {
	my $self = shift;

	# first rollback partially comitted transactions if there are any
	if ( -d ( my $b = $self->_backups ) ) {
		foreach my $name ( IO::Dir->new($b)->read ) {
			next if $name eq '.' || $name eq '..';

			my $txn_backup = File::Spec->catdir($b, $name); # each of these is one transaction

			my $files = $self->get_file_list($txn_backup);

			# move all the backups back into the root directory
			$self->merge_overlay( from => $txn_backup, to => $self->_root, files => $files );

			remove_tree($txn_backup);
		}
	}

	# delete all temp files (fully comitted but not cleaned up transactions,
	# and uncomitted transactions)
	if ( -d $self->_txns ) {
		remove_tree( $self->_txns, { keep_root => 1 } );
	}
}

sub get_file_list {
	my ( $self, $from ) = @_;

	my $files = Set::Object->new;

	find( { no_chdir => 1, wanted   => sub { $files->insert( File::Spec->abs2rel($_, $from) ) if -f $_ } }, $from );

	return $files;
}

sub merge_overlay {
	my ( $self, %args ) = @_;

	my ( $from, $to, $backup, $files ) = @args{qw(from to backup files)};

	my @rem;

	# if requested, back up first by moving all the files from the target
	# directory to the backup directory
	if ( $backup ) {
		foreach my $file ( $files->members ) {
			my $src = File::Spec->catfile($to, $file);

			next unless -e $src; # there is no source file to back

			my $targ = File::Spec->catfile($backup, $file);

			# create the parent directory in the backup dir as necessary
			my ( undef, $dir ) = File::Spec->splitpath($targ);
			if ( $dir ) {
				make_path($dir) unless -d $dir;
			}

			CORE::rename $src, $targ or die $!;
		}
	}

	# then apply all the changes to the target dir from the source dir
	foreach my $file ( $files->members ) {
		my $src = File::Spec->catfile($from,$file);

		if ( -f $src ) {
			my $targ = File::Spec->catfile($to,$file);

			# make sure the parent directory in the target path exists first
			my ( undef, $dir ) = File::Spec->splitpath($targ);
			if ( $dir ) {
				make_path($dir) unless -d $dir;
			}

			if ( -f $src ) {
				CORE::rename $src => $targ or die $!;
			} elsif ( -f $targ ) {
				CORE::unlink $targ or die $!;
			}
		}
	}
}

sub txn_begin {
	my $self = shift;

	my $txn;

	if ( my $p = $self->_txn ) {
		# this is a child transaction
		$txn = Directory::Transactional::TXN::Nested->new(
			parent  => $p,
			manager => $self,
		);
	} else {
		# this is a top level transaction
		$txn = Directory::Transactional::TXN::Root->new(
			manager => $self,
			( $self->global_lock ? ( global_lock => $self->_get_lock( $self->_txn_lock_file, LOCK_EX ) ) : () ),
		);
	}

	$self->_txn($txn);

	return;
}

sub _pop_txn {
	my $self = shift;

	my $txn = $self->_txn;

	if ( $txn->isa("Directory::Transactional::TXN::Nested") ) {
		$self->_txn( $txn->parent );
	} else {
		$self->_clear_txn;
	}

	return $txn;
}

sub txn_commit {
	my $self = shift;

	my $txn = $self->_pop_txn;

	my $changed = $txn->changed;

	if ( $changed->size ) {
		if ( $txn->isa("Directory::Transactional::TXN::Root") ) {
			# commit the work, backing up in the backup dir
			$self->merge_overlay( from => $txn->work, to => $self->_root, backup => $txn->backup, files => $changed );

			# we're finished, remove backup dir denoting successful commit
			CORE::rename $txn->backup, $txn->work . ".cleanup" or die $!;
		} else {
			# it's a nested transaction, which means we don't need to be
			# careful about comitting to the parent, just share all the locks,
			# deletion metadata etc by merging it
			$txn->propagate;

			$self->merge_overlay( from => $txn->work, to => $txn->parent->work, files => $changed );
		}

		# clean up work dir and backup dir
		remove_tree( $txn->work );
		remove_tree( $txn->work . ".cleanup" );
	}

	return;
}

sub txn_rollback {
	my $self = shift;

	my $txn = $self->_pop_txn;

	# any inherited locks that have been upgraded in this txn need to be
	# downgraded back to shared locks
	foreach my $lock ( @{ $txn->downgrade } ) {
		$lock->downgrade;
	}

	# now all we need to do is trash the tempfiles and we're done
	if ( $txn->has_work ) {
		remove_tree( $txn->work );
	}

	return;
}

# lock a path for reading
sub lock_path_read {
	my ( $self, $path, $skip_parent ) = @_;

	return if $self->global_lock;


	# create a list of ancestor directories
	my @paths;

	unless ( $skip_parent ) {
		my @dirs = File::Spec->splitdir($path);
		pop @dirs;

		if ( @dirs ) {
			for ( my $next = shift @dirs; @dirs; $next = File::Spec->catdir($next, shift @dirs) ) {
				push @paths, $next;
			}
		}
	}


	my $txn = $self->_txn;

	foreach my $path ( @paths, $path ) {
		# any type of lock in this or any parent transaction is going to be good enough
		unless ( $txn->find_lock($path) ) {
			$txn->set_lock( $path, $self->_get_flock( File::Spec->catfile( $self->_locks, $path . ".lock" ), LOCK_SH) );
		}
	}
}

sub lock_path_write {
	my ( $self, $path, $skip_parent ) = @_;

	return if $self->global_lock;

	# lock the ancestor directories for reading
	unless ( $skip_parent ) {
		my ( undef, $dir ) = File::Spec->splitpath($path);
		$self->lock_path_read($dir) if $dir;
}

	my $txn = $self->_txn;

	if ( my $lock = $txn->get_lock($path) ) {
		# simplest scenario, we already have a lock in this transaction
		$lock->upgrade; # upgrade it if necessary

	} elsif ( my $inherited_lock = $txn->find_lock($path) ) {
		# a parent transaction has a lock
		if ( $inherited_lock->is_shared ) {
			# upgrade it, and mark for downgrade on rollback
			$inherited_lock->upgrade;
			push @{ $txn->downgrade }, $inherited_lock;
		}
		$txn->set_lock( $path, $inherited_lock );
	} else {
		# otherwise create a new lock
		$txn->set_lock( $path, $self->_get_flock( File::Spec->catfile( $self->_locks, $path . ".lock" ), LOCK_EX) );
	}
}

sub _txn_for_path {
	my ( $self, $path ) = @_;

	my $txn = $self->_txn;

	do {
		if ( $txn->is_changed($path) ) {
			return $txn;
		};
	} while ( $txn->can("parent") and $txn = $txn->parent );

	return;
}

sub _locate_path_in_overlays {
	my ( $self, $path ) = @_;

	if ( my $txn = $self->_txn_for_path($path) ) {
		File::Spec->catfile($txn->work, $path);
	} else {
		$self->lock_path_read($path);
		File::Spec->catfile($self->_root, $path);
	}
}

sub old_stat {
	my ( $self, $path ) = @_;

	CORE::stat($self->_locate_path_in_overlays($path));
}

sub stat {
	my ( $self, $path ) = @_;

	require File::stat;
	File::stat::stat($self->_locate_path_in_overlays($path));
}

sub is_deleted {
	my ( $self, $path ) = @_;

	not $self->exists($path);
}

sub exists {
	my ( $self, $path ) = @_;
	return -e $self->_locate_path_in_overlays($path);
}

sub unlink {
	my ( $self, $path ) = @_;

	# lock parent for writing
	my ( undef, $dir ) = File::Spec->splitpath($path);
	$self->lock_path_write($dir) if $dir;

	my $txn_file = $self->work_path($path);

	if ( -e $txn_file ) {
		CORE::unlink $txn_file or die $!;
	} else {
		return 1;
	}
}

sub rename {
	my ( $self, $from, $to ) = @_;

	foreach my $path ( $from, $to ) {
		# lock parents for writing
		my ( undef, $dir ) = File::Spec->splitpath($path);
		$self->lock_path_write($dir) if $dir;
	}

	$self->vivify_path($from),

	CORE::rename (
		$self->work_path($from),
		$self->work_path($to),
	) or die $!;
}

sub vivify_path {
	my ( $self, $path ) = @_;

	my $txn_path = File::Spec->catfile( $self->_txn->work, $path );

	unless ( -e $txn_path ) {
		my ( undef, $dir ) = File::Spec->splitpath($path);
		make_path( File::Spec->catdir($self->_txn->work, $dir ) ) if $dir; # FIXME only if it exists in the original?

		copy( $self->_locate_path_in_overlays($path), $txn_path ) or die $!;
	}

	return $txn_path;
}

sub work_path {
	my ( $self, $path ) = @_;

	$self->lock_path_write($path);

	$self->_txn->mark_changed($path);

	my $file = File::Spec->catfile( $self->_txn->work, $path );

	my ( undef, $dir ) = File::Spec->splitpath($path);
	make_path( File::Spec->catdir($self->_txn->work, $dir ) ) if $dir; # FIXME only if it exists in the original?

	return $file;
}

__PACKAGE__->meta->make_immutable;

__PACKAGE__

__END__

=pod

=head1 NAME

Directory::Transactional - ACID transactions on a set of files with
journalling/recovery using C<flock> or L<File::NFSLock>

=head1 SYNOPSIS

	use Directory::Transactional;

	my $d = Directory::Transactional->new( root => $path );

	$d->txn_begin;

	$d->txn_commit;

=head1 DESCRIPTION

This module provides lock based transactions over a set of files with full
supported for nested transactions.

=head1 THE RULES

There are a few limitations to what this module can do.

Following this guideline will prevent unpleasant encounters:

=over 4

=item Always use relative paths

No attempt is made to sanify paths reaching outside of the root.

All paths are assumed to be relative and within the root.

=item No funny stuff

Stick with plain files, with a link count of 1, or you will not get what you
expect.

For instance a rename will first copy the source file to the txn work dir, and
then when comitting rename that file to the target dir and unlink the original.

While seemingly more work, this is the only way to ensure that modifications to
the file both before and after the rename are consistent.

Modifications to directories are likewise not supported, but support may be
added in the future.

=item Always work in a transaction

If you don't need transaction, use a global lock file and don't use this
module.

If you do, then make sure even your read access goes through this object with
an active transaction, or you may risk reading uncomitted data, or conflicting
with the transaction commit code.

=item Use C<global_lock> or make sure you lock right

If you stick to modifying the files through the API then you shouldn't have
issues with locking, but try not to reuse paths and always reask for them to
ensure that the right "real" path is returned even if the transaction stack has
changed, or anything else.

=head1 ACID GUARANTEES

ACID stands for atomicity, consistency, isolation and durability.

Transactions are atomic (using locks), consistent (a recovery mode is able to
restore the state of the directory if a process crashed while comitting a
transaction), isolated (each transaction works in its own temporary directory,
and durable (once C<txn_commit> returns a software crash will not call the
transaction to rollback).

=head1 TRANSACTIONAL PROTOCOL

This section describes the way the ACID guarantees are met:

When the object is being constructed a nonblocking attempt to get an exclusive
lock on the global shared lock file using L<File::NFSLock> or C<flock> is made.

If this lock is successful this means that this object is the only active
instance, and no other instance can access the directory for now.

The work directory's state is inspected, any partially comitted transactions
are rolled back, and all work files are cleaned up, producing a consistent
state.

At this point the exclusive lock is dropped, and a shared lock on the same file
is taken, which will be retained for the lifetime of the object.

Each transaction (root or nested) gets its own work directory, which is an
overlay of its parent.

All write operations are performed in the work directory, while read operations
walk up the tree.

Aborting a transaction consists of simply removing its work directory.

Comitting a nested transaction involves overwriting its parent's work directory
with all the changes in the child transaction's work directory.

Comitting a root transaction to the root directory involves moving aside every
file from the root to a backup directory, then applying the changes in the work
directory to the root, renaming the backup directory to a work directory, and
then cleaning up the work directory and the renamed backup directory.

If at any point in the root transaction commit work is interrupted, the backup
directory acts like a journal entry. Recovery will rollback this transaction by
restoring all the renamed backup files. Moving the backup directory into the
work directory signifies that the transaction has comitted successfully, and
recovery will clean these files up normally.

=head1 ATTRIBUTES

=over 4

=item root

This is the managed directory in which transactional semantics will be maintained.

This can be either a string path or a L<Path::Class::Dir>.

=item _work

This attribute is named with a leading underscore to prevent thoughtless
modification (if you have two workers accessing the same directory
simultaneously but the work dir is different they will conflict and not even
know it).

The default work directory is placed under root, and is named C<.txn_work_dir>.

The work dir's parent must be writable, because a lock file needs to be created
next to it (the workdir name with C<.lock> appended).

=item nfs

If true (defaults to false), L<File::NFSLock> will be used for all locks
instead of C<flock>.

Note that on my machine the stress test reliably B<FAILS> with
L<File::NFSLock>, due to a race condition (exclusive write lock granted to two
writers simultaneously), even on a local filesystem. If you specify the C<nfs>
flag make sure your C<link> system call is truly atomic.

=item global_lock

If true instead of using fine grained locking, a global write lock is obtained
on the first call to C<txn_begin> and will be kept for as long as there is a
running transaction.

This is useful for avoiding deadlocks (there is no deadlock detection code in
the fine grained locking).

This flag is automatically set if C<nfs> is set.

=item METHODS

=head2 Transaction Management

=over 4

=item txn_do $code, %callbacks

Executes C<$code> within a transaction in an C<eval> block.

If any error is thrown the transaction will be rolled back. Otherwise the
transaction is comitted.

C<%callbacks> can contain entries for C<commit> and C<rollback>, which are
called when the appropriate action is taken.

=item txn_begin

Begin a new transaction. Can be called even if there is already a running
transaction (nested transactions are supported).

=item txn_commit

Commit the current transaction. If it is a nested transaction, it will commit
to the parent transaction's work directory.

=item txn_rollback

Discard the current transaction, throwing away all changes since the last call
to C<txn_begin>.

=back

=head2 Lock Management

=over 4

=item lock_path_read $path, $no_parent

=item lock_path_write $path, $no_parent

Lock the resource at C<$path> for writing or reading.

By default the ancestors of C<$path> will be locked for reading to (from
outermost to innermost).

The only way to unlock a resource is by comitting the root transaction, or
aborting the transaction in which the resource was locked.

C<$path> does not have to be a real file in the C<root> directory, it is
possible to use symbolic names in order to avoid deadlocks.

Note that these methods are no-ops if C<global_lock> is set.

=back

=cut


