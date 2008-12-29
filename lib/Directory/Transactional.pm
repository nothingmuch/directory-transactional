#!/usr/bin/perl

package Directory::Transactional;
use Moose;

use Carp;
use Path::Class;
use Fcntl qw(LOCK_EX LOCK_SH LOCK_NB);

use File::Basename qw(dirname basename);
use File::Path qw(mkpath);

use MooseX::Types::Path::Class qw(Dir File);

use Directory::Transactional::TXN::Root;
use Directory::Transactional::TXN::Nested;

use namespace::clean -except => 'meta';

has root => (
	isa => Dir,
	is  => "ro",
	required => 1,
);

has [qw(work _backups _txns _locks)] => (
	isa => Dir,
	is  => "ro",
	lazy_build => 1,
);

sub _build_work     { shift->root->subdir(".txn_work_dir") }
sub _build__txns    { shift->work->subdir("txns") }
sub _build__backups { shift->work->subdir("backups") }
sub _build__locks   { shift->work->subdir("locks") }

has nfs => (
	isa => "Bool",
	is  => "ro",
	default => 0,
);

sub _get_lock {
	my ( $self, @args ) = @_;

	return $self->nfs ? $self->_get_nfslock(@args) : $self->_get_flock(@args);
}

sub _get_nfslock {
	my ( $self, $file, $mode ) = @_;

	require File::NFSLock;
	if ( my $lock = File::NFSLock->new({
			file      => $file,
			lock_type => $mode,
		}) ) {
		return $lock;
	} elsif ( not($mode & LOCK_NB) ) {
		die $File::NFSLock::errstr;
	}

	return;
}

sub _get_flock {
	my ( $self, $file, $mode ) = @_;

	my $parent = dirname($file);
	mkpath($parent) unless -d $parent;

	open my $fh, "+>", $file;

	if ( flock($fh, $mode) ) {
		bless $fh, $mode & LOCK_EX ? "Directory::Transactional::Lock::Exclusive" : "Directory::Transactional::Lock::Shared";
		return $fh;
	} elsif ( not $!{EWOULDBLOCK} ) {
		die $!;
	}

	return;
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

has _txn => (
	isa => "Directory::Transactional::TXN",
	is  => "rw",
	clearer => "_clear_txn",
);

has _shared_lock_file => (
	isa => "Str",
	is  => "ro",
	lazy_build => 1,
);

sub _build__shared_lock_file { shift->work . ".lock" }

has shared_lock => (
	is  => "ro",
	lazy_build => 1,
);

sub _build_shared_lock {
	my $self = shift;

	my $file = $self->_shared_lock_file;

	if ( my $ex_lock = $self->_get_lock( $file, LOCK_EX|LOCK_NB ) ) {
		# we have an exclusive lock, which means no other process is working on
		# this yet, they will be blocked on the shared lock below
		$self->recover;

		undef $ex_lock;
	}

	$self->_get_lock($file, LOCK_SH);
}

sub BUILD {
	my $self = shift;

	# obtains the shared lock, running recovery if needed
	$self->shared_lock;

	$self->work->mkpath;
}

sub DEMOLISH {
	my $self = shift;

	# rollback any open txns
	while ( $self->_txn ) {
		$self->txn_rollback;
	}

	$self->clear_shared_lock;

	# cleanup workdirs
	# only remove if no other workers are active, so that there is no race
	# condition in their directory creation code
	if ( my $ex_lock = $self->_get_lock( $self->_shared_lock_file, LOCK_EX|LOCK_NB ) ) {
		# we don't really care if there's an error
		$self->_locks->rmtree({});
		rmdir $self->_txns;
		rmdir $self->_backups;
		unlink $self->work->file("txn_lock");
		rmdir $self->work;

		unlink $self->_shared_lock_file;
	}
}

sub recover {
	my $self = shift;

	# rollback partially comitted transactions
	if ( -d $self->_backups ) {
		foreach my $txn_backup ( $self->_backups->children ) {
			$self->merge_overlay( from => $txn_backup, to => $self->root );
			$txn_backup->rmtree;
		}
	}

	# delete all temp files (fully comitted but not cleaned up transactions,
	# and uncomitted transactions)
	if ( -d $self->_txns ) {
		$self->_txns->rmtree({ keep_root => 1 });
	}
}

sub get_file_list {
	my ( $self, $from ) = @_;

	my @files;

	dir($from)->recurse(
		callback => sub {
			my $file = shift;

			my $rel = $file->relative($from);
			push @files, $rel->stringify;
		},
	);

	return \@files;
}

sub merge_overlay {
	my ( $self, %args ) = @_;

	my ( $from, $to, $backup, $changes ) = @args{qw(from to backup changes)};

	$changes ||= $self->get_file_list($from);

	if ( $backup ) {
		foreach my $change ( @$changes ) {
			my $file = ref $change ? $$change : $change;

			my $src = $to->file($file);

			next unless -e $src;

			my $targ = $backup->file($file);

			my $p = $targ->parent;
			$p->mkpath unless -d $p;

			rename $src, $targ;
		}
	}

	foreach my $change ( @$changes ) {
		if ( ref $change ) {
			unlink $$change or die $!;
		} else {
			my $src = $from->file($change);
			my $targ = $to->file($change);

			my $p = $targ->parent;
			$p->mkpath unless -d $p;

			rename $src => $targ;
		}
	}
}

sub txn_begin {
	my $self = shift;

	my $txn;

	if ( my $p = $self->_txn ) {
		$txn = Directory::Transactional::TXN::Nested->new(
			parent => $p,
			manager => $self,
		);
	} else {
		$txn = Directory::Transactional::TXN::Root->new(
			manager     => $self,
			( $self->nfs ? ( global_lock => $self->_get_lock( $self->work->file("txn_lock")->stringify, LOCK_EX ) ) : () ),
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

	if ( $txn->has_work ) {
		if ( $txn->isa("Directory::Transactional::TXN::Root") ) {
			# commit the work, backing up in the backup dir
			$self->merge_overlay( from => $txn->work, to => $self->root, backup => $txn->backup, changes => $txn->changes );

			# we're finished, remove backup dir denoting successful commit
			rename $txn->backup, $txn->work . ".cleanup";
		} else {
			# it's a nested transaction, which means we don't need to be
			# careful about comitting to the parent, just share all the locks,
			# and merge it
			$txn->propagate_locks;

			$self->merge_overlay( from => $txn->work, to => $self->_txn->work, changes => $txn->changes );
		}

		# clean up work dir
		$txn->work->rmtree;
		dir($txn->work . ".cleanup")->rmtree;
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

	if ( $txn->has_work ) {
		$txn->work->rmtree;
	}

	return;
}

sub lock_path_read {
	my ( $self, $path ) = @_;

	return if $self->nfs;

	# FIXME read lock parents

	my $txn = $self->_txn;

	# any type of lock in this or any parent transaction is going to be good enough
	unless ( $txn->find_lock($path) ) {
		$txn->set_lock( $path, $self->_get_flock( $self->_locks->file($path) . ".lock", LOCK_SH) );
	}
}

sub lock_path_write {
	my ( $self, $path ) = @_;

	return if $self->nfs;

	# FIXME read lock parents

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
		$txn->set_lock( $path, $self->_get_flock( $self->_locks->file($path) . ".lock", LOCK_EX) );
	}
}

sub remove_file {
	my ( $self, $path ) = @_;

	$self->lock_path_write($path);

	$self->_txn->_changes->{$path} = bless \$path, "Directory::Transactional::Delete";
}

sub work_path {
	my ( $self, $path ) = @_;

	$self->lock_path_write($path);

	$self->_txn->_changes->{$path} = $path;
	$self->_txn->work->file($path);
}

__PACKAGE__->meta->make_immutable;

__PACKAGE__

__END__

=pod

=head1 NAME

Directory::Transactional - 

=head1 SYNOPSIS

	use Directory::Transactional;

=head1 DESCRIPTION

=head1 TRANSACTIONAL SEMANTICS

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

=cut


