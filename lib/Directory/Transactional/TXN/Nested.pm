#!/usr/bin/perl

package Directory::Transactional::TXN::Nested;
use Moose;

use namespace::clean -except => 'meta';

extends qw(Directory::Transactional::TXN);

has parent => (
	isa => "Directory::Transactional::TXN",
	is  => "ro",
	required => 1,
);

has _lock_cache => (
	isa => "HashRef",
	is  => "ro",
	default => sub { +{} },
);

sub find_lock {
	my ( $self, $path ) = @_;

	if ( my $lock = $self->get_lock($path) ) {
		return $lock;
	} else {
		my $c = $self->_lock_cache;

		if ( exists $c->{$path} ) {
			return $c->{$path};
		} else {
			return $c->{$path} = $self->parent->find_lock($path);
		}
	}
}

__PACKAGE__->meta->make_immutable;

__PACKAGE__

__END__

=pod

=head1 NAME

Directory::Transactional::TXN::Nested - 

=head1 SYNOPSIS

	use Directory::Transactional::TXN::Nested;

=head1 DESCRIPTION

=cut


