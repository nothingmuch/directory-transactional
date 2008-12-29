#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 5;

use ok 'Directory::Transactional'; # force Squirrel to load Moose by running before Test::TempDir
BEGIN { ok( !$INC{"Moose.pm"}, "Moose not loaded" ) }

use Test::TempDir qw(temp_root);

my $work;

{
	alarm 5;
	my $d = Directory::Transactional->new( root => temp_root );
	alarm 0;

	isa_ok( $d, "Directory::Transactional" );

	$work = $d->_work;

	ok( -d $work, "work dir created" );

}

ok( not( -d $work ), "work dir removed" );
