#!/usr/bin/perl

use strict;
use warnings;

use Test::More 'no_plan';
use Test::TempDir qw(scratch);

use ok 'Directory::Transactional';

{
	my $s = scratch();

	$s->create_tree({
		# new state:
		'root/foo.txt'        => "les foo",
		'root/bar.txt'        => "the bar",
		'root/blah/gorch.txt' => "los gorch",
	});

	my $base = $s->base;

	{
		alarm 5;
		my $d = Directory::Transactional->new(
			root => $base->subdir("root"),
			work => $base->subdir("work"),
		);
		alarm 0;

		is( $s->read('root/foo.txt'),        "les foo",   "foo.txt not touched" );
		is( $s->read('root/bar.txt'),        "the bar",   "bar.txt not touched" );
		is( $s->read('root/blah/gorch.txt'), "los gorch", "gorch.txt not touched" );
	}

	ok( not(-d $base->subdir("work")), "workdir removed" );
}

{
	my $s = scratch();

	$s->create_tree({
			# inconsistent state:
			'root/foo.txt'        => "les foo",
			'root/bar.txt'        => "the bar",
			'root/blah/gorch.txt' => "los gorch",

			# some backups
			'work/backups/123/foo.txt'        => "the foo",
			'work/backups/abc/blah/gorch.txt' => "the gorch",

			# already comitted
			'work/txns/5421/bar.txt' => "old",
		});

	my $base = $s->base;

	{
		alarm 5;
		my $d = Directory::Transactional->new(
			root => $base->subdir("root"),
			work => $base->subdir("work"),
		);
		alarm 0;

		is( $s->read('root/foo.txt'),        "the foo",   "foo.txt restored" );
		is( $s->read('root/bar.txt'),        "the bar",   "bar.txt not touched" );
		is( $s->read('root/blah/gorch.txt'), "the gorch", "gorch.txt restored" );

		ok( !$s->exists('work/backups/123/foo.txt'), "foo.txt backup file removed" );
		ok( !$s->exists('work/backups/abc/blah/gorch.txt'), "gorch.txt backup file removed" );
		ok( !$s->exists('work/txns/5421/bar.txt'), "bar.txt tempfile removed" );
	}

	ok( not(-d $base->subdir("work")), "workdir removed" );
}
