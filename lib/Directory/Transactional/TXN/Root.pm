#!/usr/bin/perl

package Directory::Transactional::TXN::Root;
use Squirrel;

use File::Spec;
use File::Path qw(make_path remove_tree);

use namespace::clean -except => 'meta';

extends qw(Directory::Transactional::TXN);

# optional lock attr, used in NFS mode when no fine grained locking is
# available
has global_lock => (
	is  => "ro",
);

has backup => (
	isa => "Str",
	is  => "ro",
	lazy_build => 1,
);

sub _build_backup {
	my $self = shift;
	my $dir = File::Spec->catdir( $self->manager->_backups, $self->id );
	make_path($dir);
	return $dir;
}

sub find_lock {
	my ( $self, $path ) = @_;
	$self->get_lock($path);
}

sub is_deleted {
	my ( $self, $path ) = @_;
	$self->_deleted->{$path};
}

__PACKAGE__->meta->make_immutable;

__PACKAGE__

__END__

=pod

=head1 NAME

Directory::Transactional::TXN::Root - 

=head1 SYNOPSIS

	use Directory::Transactional::TXN::Root;

=head1 DESCRIPTION

=cut


