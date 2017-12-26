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

package history;

use strict;
use warnings;

require Exporter;
our @ISA = qw|Exporter|;
our @EXPORT = qw|history_init history_advance|;

use xlinux;
use ring;
use util;

sub history_init
{
  my ($type, $name, $profile) = @_;

  # initialize history files
  my $history = {};
  $$history{dir} = "$::opts{datadir}/history/$type/$name";
  if($type ne "profile")
  {
    $$history{dir} .= "/profile/" . $profile;
  }

  $$history{head} = readlink("$$history{dir}/head");
  $$history{head} = int $$history{head} if $$history{head};

  $$history{tail} = readlink("$$history{dir}/tail");
  $$history{tail} = int $$history{tail} if $$history{tail};

  # prune history files outside the retention window
  if(defined $$history{head} and defined $$history{tail})
  {
    while(ring_sub($$history{head}, $$history{tail}, 0xffff) > $::opts{"history-retention"})
    {
      uxunlink(sprintf("%s/%05u", $$history{dir}, $$history{tail}));
      $$history{tail} = ring_add($$history{tail}, 1, 0xffff);
    }
    symlinkf(sprintf("%05u", $$history{tail}), "$$history{dir}/tail");
  }

  return $history;
}

sub history_advance
{
  my ($history, $bench_path) = @_;

  # advance the history files
  $$history{head} = 0 unless $$history{head};
  $$history{head} = ring_add($$history{head}, 1, 0xffff);
  symlinkf($bench_path, sprintf("%s/%05u", $$history{dir}, $$history{head}));
  symlinkf(sprintf("%05u", $$history{head}), "$$history{dir}/head");

  if(not defined $$history{tail})
  {
    $$history{tail} = $$history{head};
    symlinkf(sprintf("%05u", $$history{tail}), "$$history{dir}/tail");
  }
  elsif(ring_sub($$history{head}, $$history{tail}, 0xffff) >= $::opts{"history-retention"})
  {
    uxunlink(sprintf("%s/%05u", $$history{dir}, $$history{tail}));
    $$history{tail} = ring_add($$history{tail}, 1, 0xffff);
    symlinkf(sprintf("%05u", $$history{tail}), "$$history{dir}/tail");
  }
}
