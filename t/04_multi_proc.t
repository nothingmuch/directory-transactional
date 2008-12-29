#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use File::Spec::Functions;

use constant FORKS => 6;

BEGIN {
	if ( File::Spec->isa("File::Spec::Unix") ) {
		plan tests => 1 + 9 * (FORKS+1 + 3);
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
	foreach my $global_lock ( $forks < 3 ? ( 1, 0) : (0) ) {
		my $s = scratch();

		$s->create_tree({
			# inconsistent state:
			'foo.txt'   => "les foo",
			'bar.txt'   => "the bar",
			'baz.txt'   => "the baz",
			'gorch.txt' => "los gorch",
			'bloo/blah/counter.txt' => "7",

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
					global_lock => $global_lock,
					root        => $base,
					_work       => $base->subdir("work")->stringify,
				);
				alarm 0;

				{
					$d->txn_begin;

					my $path = $d->work_path("bloo/blah/counter.txt");

					my $count = $s->read("bloo/blah/counter.txt");

					open my $fh, ">", $path or die $!;
					$fh->print( $count + 1, "\n" );
					close $fh or die $!;

					$d->txn_commit;
				}

				{
					$d->txn_begin;

					my $path = $d->work_path( my $blort = catfile("flarb", "blort_" . int(rand 10) . ".txt") );

					my $count = $s->exists($blort) ? $s->read($blort) : 0;

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

			is( $s->read('foo.txt'),   "the foo",   "foo.txt restored" );
			is( $s->read('bar.txt'),   "the bar",   "bar.txt not touched" );
			is( $s->read('baz.txt'),   "the baz",   "baz.txt not touched" );
			is( $s->read('gorch.txt'), "the gorch", "gorch.txt restored" );

			is( $s->read("bloo/blah/counter.txt"), 7 + 2 ** $forks, "counter updated the right number of times, no race conditions" );

			my $sum = 0;

			for ( 0 .. 9 ) {
				if ( $s->exists(my $file = "flarb/blort_${_}.txt" ) ) {
					$sum += $s->read($file);
				}
			}

			is( $sum, 2 ** $forks, "distributed counter updated right number of times" );

			ok( !$s->exists('work/backups/123/foo.txt'), "foo.txt backup file removed" );
			ok( !$s->exists('work/backups/abc/gorch.txt'), "gorch.txt backup file removed" );
			ok( !$s->exists('work/txns/5421/bar.txt'), "bar.txt tempfile removed" );
		}

		local $SIG{__WARN__} = sub { }; # make Directory::Scratch shut up
		undef $s;
	}
}
