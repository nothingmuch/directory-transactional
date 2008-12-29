#!/usr/bin/perl

package Directory::Transactional;
use Moose;

use Carp;
use Path::Class;
use Fcntl qw(LOCK_EX LOCK_SH LOCK_NB);

use MooseX::Types::Path::Class qw(Dir File);

use Directory::Transactional::TXN::Root;
use Directory::Transactional::TXN::Nested;

use namespace::clean -except => 'meta';

has root => (
	isa => Dir,
	is  => "ro",
	required => 1,
);

has work => (
	isa => Dir,
	is  => "ro",
	lazy_build => 1,
);

has nfs => (
	isa => "Bool",
	is  => "ro",
	default => 0,
);

sub _get_lock {
	my ( $self, $file, $mode ) = @_;

	if ( $self->nfs ) {
		require File::NFSLock;
		if ( my $lock = File::NFSLock->new({
			file      => $file,
			lock_type => $mode,
		}) ) {
			return $lock;
		} elsif ( not($mode & LOCK_NB) ) {
			die $File::NFSLock::errstr;
		}
	} else {
		open my $fh, "+>", $file;

		if ( flock($fh, $mode) ) {
			return $fh;
		} elsif ( not($mode & LOCK_NB) ) {
			die $!;
		}
	}

	return;
}

has _txn => (
	isa => "Directory::Transactional::TXN",
	is  => "rw",
	clearer => "_clear_txn",
);

sub _build_work { shift->root->subdir(".txn_work_dir") }

has _txns => (
	isa => Dir,
	is  => "ro",
	lazy_build => 1,
);

sub _build__txns { shift->work->subdir("txns") }

has _backups => (
	isa => Dir,
	is  => "ro",
	lazy_build => 1,
);

sub _build__backups { shift->work->subdir("backups") }

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
			$self->merge_overlay( $txn_backup => $self->root );
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
			push @files, $rel;
		},
	);

	return @files;
}

sub merge_overlay {
	my ( $self, $from, $to, $backup ) = @_;

	my @files = $self->get_file_list($from);

	if ( $backup ) {
		foreach my $file ( @files ) {
			my $src = $to->file($file);

			next unless -e $src;

			my $targ = $backup->file($file);

			my $p = $targ->parent;
			$p->mkpath unless -d $p;

			rename $src, $targ;
		}
	}

	foreach my $file ( @files ) {
		my $src = $from->file($file);
		my $targ = $to->file($file);

		my $p = $targ->parent;
		$p->mkpath unless -d $p;

		rename $src => $targ;
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
			global_lock => $self->_get_lock( $self->work->file("txn_lock")->stringify, LOCK_EX ),
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
			$self->merge_overlay( $txn->work, $self->root, $txn->backup );

			# we're finished, remove backup dir denoting successful commit
			rename $txn->backup, $txn->work . ".cleanup";
			$txn->clear_backup;
		} else {
			# it's a nested transaction, which means we don't need to be
			# careful about comitting to the parent, just merge it
			$self->merge_overlay( $txn->work, $self->_txn->work );
		}

		# clean up work dir
		$txn->work->rmtree;
		dir($txn->work . ".cleanup")->rmtree;
		$txn->clear_work;
	}

	return;
}

sub txn_rollback {
	my $self = shift;

	$self->_pop_txn;

	return;
}

sub work_path {
	my ( $self, $path ) = @_;
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
lock on the global shared lock file using L<File::NFSLock> is made.

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
directory to the root, moving the backup directory into the work directory, and
then cleaning up the work directory.

If at any point in the root transaction commit work is interrupted, the backup
directory acts like a journal entry. Recovery will rollback this transaction by
restoring all the renamed backup files. Moving the backup directory into the
work directory signifies that the transaction has comitted successfully, and
recovery will clean these files up normally.

=cut


