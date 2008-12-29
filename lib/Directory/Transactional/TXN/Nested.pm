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


