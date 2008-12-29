#!/usr/bin/perl

package Directory::Transactional::TXN;
use Squirrel;

use Set::Object;
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

has work => (
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

has _locks => (
	isa => "HashRef",
	is  => "ro",
	default => sub { {} },
);

has changed => (
	isa => "Set::Object",
	is  => "ro",
	default => sub { Set::Object->new },
);

has [qw(downgrade)] => (
	isa => "ArrayRef",
	is  => "ro",
	default => sub { [] },
);

sub propagate {
	my $self = shift;

	my $p = $self->parent;

	foreach my $field ( qw(_locks) ) {
		my $h = $self->$field;
		@{ $self->parent->$field }{ keys %$h } = values %$h;
	}

	$self->parent->changed->insert($self->changed->members);

	return;
}

sub set_lock {
	my ( $self, $path, $lock ) = @_;
	$self->_locks->{$path} = $lock;
}

sub get_lock {
	my ( $self, $path ) = @_;
	$self->_locks->{$path};
}

sub is_changed {
	my ( $self, $path ) = @_;

	$self->changed->includes($path);
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

sub mark_changed {
	my ( $self, @args ) = @_;
	$self->changed->insert(@args);
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


