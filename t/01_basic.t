#!/usr/bin/perl

use strict;
use warnings;

use Test::More tests => 4;
use Test::TempDir qw(temp_root);

use ok 'Directory::Transactional';

my $work;

{
	alarm 5;
	my $d = Directory::Transactional->new( root => temp_root );
	alarm 0;

	isa_ok( $d, "Directory::Transactional" );

	$work = $d->work;

	ok( -d $work, "work dir created" );

}

ok( not( -d $work ), "work dir removed" );
