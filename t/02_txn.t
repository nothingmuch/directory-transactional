#!/usr/bin/perl

use strict;
use warnings;

use Path::Class;
use File::Spec::Functions;

use Test::More 'no_plan';
use Test::TempDir qw(temp_root);

use ok 'Directory::Transactional';

my $name = catfile("foo", "foo.txt");
my $file = temp_root->file($name);


my $work;

{
	alarm 5;
	my $d = Directory::Transactional->new( root => temp_root );
	alarm 0;

	isa_ok( $d, "Directory::Transactional" );
	$work = $d->_work;

	ok( not(-e $file), "file does not exist" );

	{
		$d->txn_begin;

		my $path = $d->work_path($name);

		ok( -d $work, "work dir created" );

		ok( not(-e $file), "root file does not exist after starting txn" );

		open my $fh, ">", $path;
		$fh->print("dancing\n");
		close $fh;

		ok( not(-e $file), "root file does not exist after writing" );

		$d->txn_commit;
	}

	ok( -e $file, "file exists after comitting" );

	is( $file->slurp, "dancing\n", "file contents" );

	{
		$d->txn_begin;

		my $outer_path = $d->work_path($name);

		ok( not( -e $outer_path ), "txn not yet modified" );

		is( $file->slurp, "dancing\n", "root file not yet modified" );

		{
			$d->txn_begin;

			my $path = $d->work_path($name);

			open my $fh, ">", $path;
			$fh->print("hippies\n");
			close $fh;

			ok( not( -e $outer_path ), "txn not yet modified" );

			is( $file->slurp, "dancing\n", "root file not yet modified" );

			$d->txn_commit;
		}

		is( file($outer_path)->slurp, "hippies\n", "nested transaction comitted to parent" );

		is( $file->slurp, "dancing\n", "root file not yet modified" );

		$d->txn_commit;
	}

	is( $file->slurp, "hippies\n", "root file comitted" );

	{
		$d->txn_begin;

		my $path = $d->work_path($name);

		ok( -d $work, "work dir created" );

		is( $file->slurp, "hippies\n", "root file unmodified" );

		open my $fh, ">", $path;
		$fh->print("hairy\n");
		close $fh;

		is( $file->slurp, "hippies\n", "root file unmodified" );

		$d->txn_rollback;
	}

	is( $file->slurp, "hippies\n", "root file unmodified" );
}

ok( not( -d $work ), "work dir removed" );

