#!/bin/env perl

# Copyright (c) 2017 Todd Freed <todd.freed@gmail.com>
# 
# This file is part of autominer.
# 
# autominer is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# autominer is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License

package util;

use strict;
use warnings;

require Exporter;
our @ISA = qw|Exporter|;
our @EXPORT = (
    qw|run killfast curl filter override_warn_and_die lock_obtain|
  , qw|mkdirp symlinkf|
);

use File::Temp;
use Errno ':POSIX';
use Fcntl;
use Fcntl 'SEEK_SET';
use POSIX;
use MIME::Base64;
use Data::Dumper;

use xlinux;

sub override_warn_and_die
{
  $SIG{__WARN__} = sub { die @_ };
  $SIG{__DIE__} = sub {
    die @_ if $^S;
    die @_ unless $_[0] =~ /(.*) at .* line.*$/m;
    die "$1\n"
  };
}

#
# presumes a SIGCHLD which zeroes the pidref
#
sub killfast
{
  my $pidrefs = shift;

  # ask politely
  for my $pidref (@$pidrefs)
  {
    my $p = $$pidref;
    kill 15, $p if $p;
  }

  # wait for compliance
  my $secs = 3;
  my $interval = .01;
  my $maxiter = $secs * $interval;
  my $x;
  for($x = 0; $x < $maxiter; $x++)
  {
    select undef, undef, undef, $interval;
    my $y;
    for($y = 0; $y <= $#$pidrefs; $y++)
    {
      last if ${$$pidrefs[$y]};
    }

    last if $y > $#$pidrefs;
  }

  return if $x < $maxiter;

  # murder
  for my $pidref (@$pidrefs)
  {
    my $p = $$pidref;
    kill 9, $p if $p;
  }
}

sub curl
{
  my $url = shift;
  my %params = @_;

  my $query = '';
  while(my($k, $v) = each %params)
  {
    $query .= "&" if $query;
    $query .= "?" if not $query;

    $query .= $k;
    $query .= "=";
    $query .= $v;
  }

  my($read_fd, $write_fd) = POSIX::pipe() or die;
  my $pid = fork;
  if(!$pid)
  {
    POSIX::close($read_fd);

    open(my $wh, "<&=$write_fd") or die;
    my $flags = fcntl $wh, F_GETFD, 0 or die $!;
    fcntl $wh, F_SETFD, $flags &= ~FD_CLOEXEC or die $!;

    my @cmd = (
        "curl"
      , "${url}${query}"
      , "-s"
      , "-o", "/dev/fd/$write_fd" # . fileno($wh)
    );

    print STDERR (" > @cmd\n") if $::verbose;
    exec { $cmd[0] } @cmd;
  }

  POSIX::close($write_fd) or die $!;

  my $output = '';
  while(1)
  {
    my $data;
    my $r = POSIX::read($read_fd, $data, 0xffff);
    die "read($read_fd) : $!" unless defined $r;
    last if $r == 0;
    $output .= $data;
  }

  chomp $output if $output;
  POSIX::close($read_fd) or die $!;

  $output
}

sub run
{
  my @cmd = @_;
  print STDERR (" > @cmd\n") if $::verbose;

  my($read_fd, $write_fd) = POSIX::pipe() or die;
  my $pid = fork;
  if(!$pid)
  {
    POSIX::close($read_fd);

    open(STDIN, "</dev/null");
    open(STDOUT, ">&=$write_fd") or die;
    chdir("/") or die;

    exec { $cmd[0] } @cmd;
  }

  POSIX::close($write_fd) or die $!;

  my $output = '';
  while(1)
  {
    my $data;
    my $r = POSIX::read($read_fd, $data, 0xffff);
    die "read($read_fd) : $!" unless defined $r;
    last if $r == 0;
    $output .= $data;
  }

  chomp $output if $output;
  POSIX::close($read_fd) or die $!;

  $output
}

sub filter
{
  my ($cmd, $text) = @_;

  my($in_reader, $in_writer) = POSIX::pipe() or die;
  my($out_reader, $out_writer) = POSIX::pipe() or die;
  my $pid = fork;
  if($pid == 0)
  {
    POSIX::close($in_writer) or die;
    POSIX::dup2($in_reader, 0) or die;
    POSIX::close($in_reader) or die;

    POSIX::close($out_reader) or die;
    POSIX::dup2($out_writer, 1) or die;
    POSIX::close($out_writer) or die;

    pr_set_pdeathsig(9);

    exec { $$cmd[0] } @$cmd;
  }

  print(" [$pid] @$cmd\n") if $::verbose;

  POSIX::close($in_reader) or die;
  POSIX::close($out_writer) or die;

  if($text)
  {
    POSIX::write($in_writer, $text, length($text)) or die $!;
  }
  POSIX::close($in_writer) or die;

  my $output = '';
  while(1)
  {
    my $data;
    my $r = POSIX::read($out_reader, $data, 0xffff);
    die "read($out_reader) : $!" unless defined $r;
    last if $r == 0;
    $output .= $data;
  }

  chomp $output if $output;

  POSIX::close($out_reader);
  $output;
}

sub obtain
{
  my $path = shift;

  # create the pidfile
  my $fd = uxopen($path, O_CREAT | O_WRONLY | O_EXCL);

  # success ; record our pid in the file
  if($fd >= 0)
  {
    POSIX::write($fd, "$$\n", length("$$\n"));
    POSIX::close($fd);
    return 0;
  }

  # failure ; read the pid from the file
  open(my $fh, "<$path") or die "open($path) : $!";
  my $pid = <$fh>;
  close $fh;

  chomp $pid;
  return int $pid;
}

# fatal obtain a lock by creating the specified file
sub lock_obtain
{
  my $path = shift;

  while(1)
  {
    my $pid = obtain($path);

    # lock successfully obtained
    last if $pid == 0;

    # lock holder is still running
    return $pid if kill 0, $pid;

    # forcibly release the lock
    xunlink($path);
  }

  return 0;
}

# fatal mkdir but only fail when errno != EEXIST
sub mkdirp
{
  my $path = shift;

  my @parts = 
  my $pfx = '/' if substr($path, 0, 1) eq '/';
  my $s = '';
  for my $part (split(/\/+/, $path))
  {
    next unless $part;
    $s .= "/" if $s;
    $s .= $part;
    uxmkdir("$pfx/$s") if $pfx;
    uxmkdir($s) if not $pfx;
  }
}

# rm linkpath (but dont fail if linkpath doesnt exist), then fatal symlink(target, linkpath)
sub symlinkf
{
  my ($target, $linkpath) = @_;

  uxunlink($linkpath);
  symlink($target, $linkpath) or die("symlink($target, $linkpath) : $!");
}

1
