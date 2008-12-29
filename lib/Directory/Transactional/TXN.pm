#!/usr/bin/perl

package Directory::Transactional::TXN;
use Moose;

use File::Spec;
use File::Path qw(make_path remove_tree);

use namespace::clean -except => 'meta';

has manager => (
	isa => "Directory::Transactional",
	is  => "ro",
	required => 1,
	weak_ref => 1,
);

has id => (
	isa => "Str",
	is  => "ro",
	lazy_build => 1,
);

use Data::UUID::LibUUID (
	new_dce_uuid_string => { -as => "_build_id" },
);

has [qw(work backup)] => (
	isa => "Str",
	is  => "ro",
	lazy_build => 1,
);

sub _build_work {
	my $self = shift;
	my $dir = File::Spec->catdir( $self->manager->_txns, $self->id );
	make_path($dir);
	return $dir;
}

sub _build_backup {
	my $self = shift;
	my $dir = File::Spec->catdir( $self->manager->_backups, $self->id );
	make_path($dir);
	return $dir;
}

has [qw(_changes _locks _deleted)] => (
	isa => "HashRef",
	is  => "ro",
	default => sub { {} },
);

has [qw(downgrade)] => (
	isa => "ArrayRef",
	is  => "ro",
	default => sub { [] },
);

sub propagate_locks {
	my $self = shift;

	my $l = $self->_locks;
	@{ $self->parent->_locks }{ keys %$l } = values %$l;
}

sub set_lock {
	my ( $self, $path, $lock ) = @_;
	$self->_locks->{$path} = $lock;
}

sub get_lock {
	my ( $self, $path ) = @_;
	$self->_locks->{$path};
}

sub changes {
	my $self = shift;
	return [ values %{ $self->_changes } ];
}

sub DEMOLISH {
	my $self = shift;

	if ( $self->has_work ) {
		remove_tree($self->work, {});
	}

	if ( $self->has_backup ) {
		remove_tree($self->backup, {});
	}
}

sub add_change {
	my ( $self, $change ) = @_;

	if ( ref $change ) {
		$self->_deleted->{$$change} = 1;
	}

	push @{ $self->_changes }, $change;
}

__PACKAGE__->meta->make_immutable;

__PACKAGE__

__END__

=pod

=head1 NAME

Directory::Transactional::TXN - ACID transactions on a set of files with recovery

=head1 SYNOPSIS

	use Directory::Transactional::TXN;

=head1 DESCRIPTION

=cut


