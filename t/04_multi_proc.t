#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use File::Spec;

BEGIN {
	if ( File::Spec->isa("File::Spec::Unix") ) {
		plan 'no_plan';
	} else {
		plan skip_all => "not running on something UNIXish";
	}
}

use Test::TempDir qw(scratch);

use ok 'Directory::Transactional';

{
	package Directory::Transactional;

	use Hook::LexWrap;

	# inflate the exclusive lock time
	wrap recover => pre => sub { select(undef,undef,undef,0.2) };
}

{
	my $s = scratch();

	$s->create_tree({
		# inconsistent state:
		'root/foo.txt'        => "les foo",
		'root/bar.txt'        => "the bar",
		'root/blah/gorch.txt' => "los gorch",
		'root/counter.txt'    => "7",

		# some backups
		'work/backups/123/foo.txt'        => "the foo",
		'work/backups/abc/blah/gorch.txt' => "the gorch",

		# already comitted
		'work/txns/5421/bar.txt' => "old",
	});

	my $base = $s->base;

	defined(my $pid = fork) or die $!;

	my $forks = 6;

	unless ( $pid ) {
		defined(fork) or die $! for 1 .. $forks;

		my $guard = Scope::Guard->new(sub {
			# avoid cleanups on errors
			use POSIX qw(_exit);
			_exit(0);
		});

		srand(time ^ $$); # otherwise rand returns the same in all children

		select(undef,undef,undef,0.3 * rand);

		{
			alarm 5;
			my $d = Directory::Transactional->new(
				root => $base->subdir("root"),
				work => $base->subdir("work"),
			);
			alarm 0;

			{
				$d->txn_begin;

				my $path = $d->work_path("counter.txt");

				my $count = $s->read("root/counter.txt");

				open my $fh, ">", $path or die $!;
				$fh->autoflush(1);
				$fh->print( ++$count, "\n" );
				close $fh or die $!;

				$d->txn_commit;
			}

			{
				$d->txn_begin;

				my $path = $d->work_path("foo.txt");

				open my $fh, ">", $path;
				$fh->print( "blort\n" );
				close $fh;

				$d->txn_rollback;
			}
		}

		while( wait	!= -1 ) { }
	}

	wait;

	is( $s->read('root/foo.txt'),        "the foo",   "foo.txt restored" );
	is( $s->read('root/bar.txt'),        "the bar",   "bar.txt not touched" );
	is( $s->read('root/blah/gorch.txt'), "the gorch", "gorch.txt restored" );

	is( $s->read("root/counter.txt"), 7 + 2 ** $forks, "counter updated the right number of times, no race conditions" );

	ok( !$s->exists('work/backups/123/foo.txt'), "foo.txt backup file removed" );
	ok( !$s->exists('work/backups/abc/blah/gorch.txt'), "gorch.txt backup file removed" );
	ok( !$s->exists('work/txns/5421/bar.txt'), "bar.txt tempfile removed" );
}
