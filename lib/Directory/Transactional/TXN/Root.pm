#!/usr/bin/perl

package Directory::Transactional::TXN::Root;
use Moose;

use namespace::clean -except => 'meta';

extends qw(Directory::Transactional::TXN);

has global_lock => (
	is  => "ro",
	required => 1,
);

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


