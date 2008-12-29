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


	{
		$d->txn_begin;

		ok( -e $file, "file exists" );
		is( $file->slurp, "hippies\n", "unmodified" );

		ok( !$d->is_deleted($name), "not marked as deleted" );

		$d->unlink($name);

		ok( $d->is_deleted($name), "marked as deleted" );

		ok( -e $file, "file still exists" );
		is( $file->slurp, "hippies\n", "unmodified" );

		$d->txn_commit;

		ok( not(-e $file), "file removed" );
	}

	$file->openw->print("hippies\n");

	{
		$d->txn_begin;

		ok( -e $file, "file exists" );
		is( $file->slurp, "hippies\n", "unmodified" );

		ok( !$d->is_deleted($name), "not marked as deleted" );

		{
			$d->txn_begin;

			ok( !$d->is_deleted($name), "not marked as deleted" );

			$d->unlink($name);

			ok( $d->is_deleted($name), "marked as deleted" );

			ok( -e $file, "file still exists" );
			is( $file->slurp, "hippies\n", "unmodified" );

			$d->txn_commit;
		}

		ok( $d->is_deleted($name), "marked as deleted" );

		ok( -e $file, "file still exists" );
		is( $file->slurp, "hippies\n", "unmodified" );

		$d->txn_commit;

		ok( not(-e $file), "file removed" );
	}

	$file->openw->print("hippies\n");

	{
		my $targ = temp_root->file('oi_vey.txt');

		$d->txn_begin;

		ok( -e $file, "file exists" );
		is( $file->slurp, "hippies\n", "unmodified" );

		ok( !$d->is_deleted($name), "not marked as deleted" );

		{
			$d->txn_begin;

			ok( !$d->is_deleted($name), "not marked as deleted" );
			ok( $d->is_deleted("oi_vey.txt"), "target file is considered deleted" );

			$d->rename($name, "oi_vey.txt");

			ok( !$d->is_deleted("oi_vey.txt"), "renamed not deleted" );

			ok( -e $d->work_path("oi_vey.txt"), "target exists in the txn dir" );

			my $stat = $d->stat("oi_vey.txt");
			is( $stat->nlink, 1, "file has one link (stat)" );

			ok( !$d->old_stat($name), "no stat for source file" );

			ok( $d->is_deleted($name), "marked as deleted" );

			ok( -e $file, "file still exists" );
			is( $file->slurp, "hippies\n", "unmodified" );

			$d->txn_commit;
		}

		ok( $d->is_deleted($name), "marked as deleted" );

		ok( -e $file, "file still exists" );
		is( $file->slurp, "hippies\n", "unmodified" );

		$d->txn_commit;

		ok( not(-e $file), "file removed" );

		ok( -e $targ, "target file exists" );

		is( $targ->slurp, "hippies\n", "contents" );
	}
}

ok( not( -d $work ), "work dir removed" );

