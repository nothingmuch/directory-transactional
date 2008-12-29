#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use File::Spec;

use constant FORKS => 6;

BEGIN {
	if ( File::Spec->isa("File::Spec::Unix") ) {
		plan tests => 1 + 9 * (FORKS+1);
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

foreach my $forks ( 0 .. FORKS ) {
	my $s = scratch();

	$s->create_tree({
		# inconsistent state:
		'root/foo.txt'     => "les foo",
		'root/bar.txt'     => "the bar",
		'root/baz.txt'     => "the baz",
		'root/gorch.txt'   => "los gorch",
		'root/counter.txt' => "7",

		# some backups
		'work/backups/123/foo.txt'   => "the foo",
		'work/backups/abc/gorch.txt' => "the gorch",

		# already comitted
		'work/txns/5421/bar.txt' => "old",
	});

	my $base = $s->base;

	defined(my $pid = fork) or die $!;

	unless ( $pid ) {
		my $exit = 0;

		my $guard = Scope::Guard->new(sub {
			# avoid cleanups on errors
			use POSIX qw(_exit);
			_exit($exit);
		});

		defined(fork) or $exit=1, die $! for 1 .. $forks;

		srand($$); # otherwise rand returns the same in all children

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
				$fh->print( $count + 1, "\n" );
				close $fh or die $!;

				$d->txn_commit;
			}

			{
				$d->txn_begin;

				my $path = $d->work_path( my $blort = "blort_" . int(rand 10) . ".txt" );

				my $count = $s->exists("root/$blort") ? $s->read("root/$blort") : 0;

				select(undef,undef,undef,0.05);

				open my $fh, ">", $path;
				$fh->print( $count + 1, "\n" );
				close $fh;

				$d->txn_commit;
			}
		}

		while( wait	!= -1 ) { $exit = 1 if $? }
	}

	wait;

	SKIP: {
		skip "bad exit from child", 9 if $?;

		is( $s->read('root/foo.txt'),   "the foo",   "foo.txt restored" );
		is( $s->read('root/bar.txt'),   "the bar",   "bar.txt not touched" );
		is( $s->read('root/baz.txt'),   "the baz",   "baz.txt not touched" );
		is( $s->read('root/gorch.txt'), "the gorch", "gorch.txt restored" );

		is( $s->read("root/counter.txt"), 7 + 2 ** $forks, "counter updated the right number of times, no race conditions" );

		my $sum = 0;

		for ( 0 .. 9 ) {
			if ( $s->exists(my $file = "root/blort_${_}.txt" ) ) {
				$sum += $s->read($file);
			}
		}

		is( $sum, 2 ** $forks, "distributed counter updated right number of times" );

		ok( !$s->exists('work/backups/123/foo.txt'), "foo.txt backup file removed" );
		ok( !$s->exists('work/backups/abc/gorch.txt'), "gorch.txt backup file removed" );
		ok( !$s->exists('work/txns/5421/bar.txt'), "bar.txt tempfile removed" );
	}
}
