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

package perf;

use strict;
use warnings;

require Exporter;
our @ISA = qw|Exporter|;
our @EXPORT = (
    qw|perf_readdir perf_startfile perf_readline perf_update perf_endfile perf_initialize perf_summary|
  , qw|average_rate average_speed actual_rate actual_speed opportunity_rate opportunity_speed predicted_rate predicted_speed predicted_profit|
);

use Data::Dumper;
use File::Find;

use util;
use xlinux;
use ring;

sub normalize_hashrate
{
  my ($rate, $units) = @_;

  # no label, assume raw hashes
  $units = "" unless $units;

  if($units eq "p") {
    $rate *= 1000;
    $units = 't';
  }
  if($units eq "t") {
    $rate *= 1000;
    $units = 'g';
  }
  if($units eq "g") {
    $rate *= 1000;
    $units = 'm';
  }
  if($units eq "") {
    $rate /= 1000;
    $units = "k";
  }
  if($units eq "k") {
    $rate /= 1000;
    $units = 'm';
  }

  $rate;
}

sub perf_startfile
{
  my ($miner, $algo) = @_;

  $$algo{perf_time_base} = 0;
}

# reads the output from the perf pipe
sub perf_readline
{
  my ($miner, $algo, $line) = @_;

  my $re = qr/
       ([0-9]+)        # 1 time-offset
    \s+([0-9.]+)       # 2 speed
    \s+(k|m|g|t|p)?    # 3 units
    \s*(?:h|s)\/s
  /xi;

  if($line !~ $re)
  {
#    print "malformed $$miner{name}/$$algo{name} perf record '$line'\n" if $::verbose;
  }
  else
  {
    my $time = int($1);
    my $rate = normalize_hashrate($2, $3);

    # one record per second
    while($$algo{perf_time_base} < $time)
    {
      unshift @{$$algo{perf}}, $rate;
      $$algo{perf_time_base}++;
    }
  }
}

sub perf_update
{
  my ($miner, $algo, $benchdir) = @_;

  # re-calculate algo speed
  my $speed = 0xFFFFFFFF;
  if(@{$$algo{perf}})
  {
    $speed = 0;

    my $x;
    for($x = 0; $x <= $#{$$algo{perf}}; $x++)
    {
      $speed += $$algo{perf}[$x];
    }

    $speed /= $x;
  }

  # report
  printf("%35s", sprintf("%s/%s", $$miner{name}, $$algo{name}));
  if($$algo{speed} == 0xffffffff) {
    printf("%14s", "(no data)");
  } else {
    printf("%14.8fMH/s", $$algo{speed});
  }
  printf(" => ");

  if($speed == 0xffffffff) {
    printf(" %14s", "(no data)");
  } else {
    printf(" %14.8fMH/s", $speed);
  }

  if($$algo{speed} != 0xffffffff && $speed != 0xffffffff)
  {
    my $delta = $speed - $$algo{speed};
    printf(" %%%6.2f", ($delta / $$algo{speed}) * 100);
  }
  print("\n");

  $$algo{speed} = $speed;
}

sub perf_endfile
{
  my ($miner, $algo, $benchdir, $num) = @_;

  my $dir = "$benchdir/$$miner{name}/$$algo{name}";

  # discard aged out perf records
  $#{$$algo{perf}} = $::opts{samples} if $#{$$algo{perf}} > $::opts{samples};

  # remove the file if it has now aged out
  $$algo{tail} = $num unless defined $$algo{tail};
  $$algo{head} = $num;

  if(ring_sub($$algo{head}, $$algo{tail}, 0xffff) >= $::opts{retention})
  {
    uxunlink(sprintf("%s/%05u", $dir, $$algo{tail}));
    $$algo{tail} = ring_add($$algo{tail}, 1, 0xffff);
  }

  # update the symlinks for the perf series
  symlinkf(sprintf("%05u", $$algo{tail}), "$dir/tail");
  symlinkf(sprintf("%05u", $$algo{head}), "$dir/head");
}

#
# load all of the perf records for a miner/algo and cat them onto the perf pipe
#
sub perf_readdir
{
  my ($miner, $algo, $benchdir) = @_;

  my $dir = "$benchdir/$$miner{name}/$$algo{name}";

  my $wanted = sub {
    return if $_ eq "." or $_ eq "..";

    # reset the time base for interpreting a new file
    perf_startfile($miner, $algo);

    my $fh = xfhopen("<$dir/$_");

    # discard the header
    my $line = <$fh>; $line = <$fh>;
    while($line = <$fh>)
    {
      perf_readline($miner, $algo, $line);
    }
    close $fh;

    perf_endfile($miner, $algo, $dir, int($_));
  };
  my $preprocess = sub {
    sort { int($a) <=> int($b) } # increasing order
    grep { /^[0-9]+$/ } @_
  };

  if(-d $dir)
  {
    chdir($dir) or die "chdir($dir) : $!";
    finddepth({ wanted => $wanted, preprocess => $preprocess }, ".");
  }

  perf_update($miner, $algo);
}

sub perf_initialize
{
  my ($miner, $algo, $benchdir) = @_;

  my $dir = "$benchdir/$$miner{name}/$$algo{name}";
  mkdirp($dir);

  $$algo{perf_time_base} = 0;
  ($$algo{head}, $$algo{tail}) = ring_init($dir, $::opts{retention});

  if(defined($$algo{tail}) and defined($$algo{head}))
  {
    # load history files within the samples window
    my $x = $$algo{tail};
    if(ring_sub($$algo{head}, $$algo{tail}, 0xffff) > $::opts{samples})
    {
      $x = ring_sub($$algo{head}, $::opts{samples}, 0xffff);
    }
    while(1)
    {
      if((my $fh = uxfhopen(sprintf("<%s/%05u", $dir, $x))))
      {
        # discard the header
        my $line = <$fh>; $line = <$fh>;
        while($line = <$fh>)
        {
          chomp $line;
          perf_readline($miner, $algo, $line);
        }
        close $fh;
      }

      last if $x == $$algo{head};
      $x = ring_add($x, 1, 0xffff);
    }
  }

  perf_update($miner, $algo, $benchdir);
}

sub perf_summary
{
  my ($mining, $option, $rates, $opportunities, $present) = @_;

  my $summary = sprintf("%-10s %12u %15s %30s"
    , $release::number
    , time()
    , $$option{market}
    , "$$option{miner}{name}/$$option{algo}{name}"
  );

  my @s = (' ', ' ', ' ');
  my @e = (' ', ' ', ' ');
  if($$option{algo}{name} eq $$mining{algo} && $$option{market} eq $$mining{market})
  {
    $s[2] = '(';
    $e[2] = ')';
  }
  elsif($::opts{method} eq "average")
  {
    $s[1] = '(';
    $e[1] = ')';
  }
  else
  {
    $s[0] = '(';
    $e[0] = ')';
  }
    
  $summary .= ' [';
  $summary .= sprintf("%s%14.8f%s", $s[0], opportunity_rate(@_), $e[0]);
  $summary .= sprintf(" %s%14.8f%s", $s[1], average_rate(@_), $e[1]);
  $summary .= sprintf(" %s%14.8f%s", $s[2], predicted_rate(@_), $e[2]);
  $summary .= ']';

  $summary .= sprintf(" * %14.8f = %14.8f\n"
    , predicted_speed(@_)
    , predicted_profit(@_)
  );

  return $summary;
}

sub average_rate
{
  my ($mining, $option, $rates, $opportunities, $present) = @_;

  $$rates{$$option{market}}{$$option{algo}{name}} || 0
}

sub average_speed
{
  my ($mining, $option, $rates, $opportunities, $present) = @_;

  $$option{algo}{speed}
}

sub actual_rate
{
  my ($mining, $option, $rates, $opportunities, $present) = @_;

  my $price;
  if($$option{algo}{name} eq $$mining{algo} && $$option{market} eq $$mining{market})
  {
    $price = $$present{price}
  }
  $price || 0
}

sub actual_speed
{
  my ($mining, $option, $rates, $opportunities, $present) = @_;

  my $speed;
  if($$option{algo}{name} eq $$mining{algo} && $$option{market} eq $$mining{market})
  {
    $speed = $$present{speed}
  }
  $speed || 0
}

sub opportunity_rate
{
  my ($mining, $option, $rates, $opportunities, $present) = @_;

  my $price;
  if($$opportunities{$$option{market}}{$$option{algo}{name}}{size_pct} < 10)
  {

  }
  else
  {
    $price = $$opportunities{$$option{market}}{$$option{algo}{name}}{price};
  }
  $price || 0
}

sub opportunity_speed
{
  my ($mining, $option, $rates, $opportunities, $present) = @_;

  $$option{algo}{speed} || 0
}

sub predicted_rate
{
  my ($mining, $option, $rates, $opportunities, $present) = @_;

  return actual_rate(@_) if $$option{algo}{name} eq $$mining{algo} && $$option{market} eq $$mining{market};
  return average_rate(@_) if $::opts{method} eq "average";
  return opportunity_rate(@_)
}

sub predicted_speed
{
  my ($mining, $option, $rates, $opportunities, $present) = @_;

  return actual_speed(@_) if $$option{algo}{name} eq $$mining{algo} && $$option{market} eq $$mining{market};
  return average_speed(@_)
}

sub predicted_profit
{
  my ($mining, $option, $rates, $opportunities, $present) = @_;

  predicted_rate(@_) * predicted_speed(@_)
}
