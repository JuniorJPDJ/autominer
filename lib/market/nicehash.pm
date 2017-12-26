#!/bin/env perl

package nicehash;

use strict;
use warnings;

require Exporter;
our @ISA = qw|Exporter|;
our @EXPORT = qw|nicecurl niceport stats_global_current orders_summarize current_performance|;

use util;
use JSON::XS;
use Data::Dumper;

# nicehash region config
our %regions = (
    "eu" =>       { code => 0 }
  , "usa" =>      { code => 1 }
);

our %regions_by_market = (
    "nicehash-eu"   => "eu"
  , "nicehash-usa"  => "usa"
);

# nicehash regions by number
our %regions_by_number = (
    0 => "eu"
  , 1 => "usa"
);

our %algos = (
    "axiom" =>          { code => 13 , units => 'KH/s'  , port => 3346 }
  , "blake256r14" =>    { code => 17 , units => 'TH/s'  , port => 3350 }
  , "blake256r8" =>     { code => 16 , units => 'TH/s'  , port => 3349 }
  , "blake256r8vnl" =>  { code => 18 , units => 'TH/s'  , port => 3351 }
  , "blake2s" =>        { code => 28 , units => 'TH/s'  , port => 3361 }
  , "cryptonight" =>    { code => 22 , units => 'MH/s'  , port => 3355 }
  , "daggerhashimoto" =>{ code => 20 , units => 'GH/s'  , port => 3353 }
  , "decred" =>         { code => 21 , units => 'TH/s'  , port => 3354 }
  , "equihash" =>       { code => 24 , units => 'MSol/s', port => 3357 }
  , "hodl" =>           { code => 19 , units => 'KH/s'  , port => 3352 }
  , "keccak" =>         { code => 5  , units => 'TH/s'  , port => 3338 }
  , "lbry" =>           { code => 23 , units => 'TH/s'  , port => 3356 }
  , "lyra2re" =>        { code => 9  , units => 'GH/s'  , port => 3342 }
  , "lyra2rev2" =>      { code => 14 , units => 'TH/s'  , port => 3347 }
  , "neoscrypt" =>      { code => 8  , units => 'GH/s'  , port => 3341 }
  , "nist5" =>          { code => 7  , units => 'GH/s'  , port => 3340 }
  , "pascal" =>         { code => 25 , units => 'TH/s'  , port => 3358 }
  , "quark" =>          { code => 12 , units => 'TH/s'  , port => 3345 }
  , "qubit" =>          { code => 11 , units => 'GH/s'  , port => 3344 }
  , "sha256" =>         { code => 1  , units => 'PH/s'  , port => 3334 }
  , "sia" =>            { code => 27 , units => 'TH/s'  , port => 3360 }
  , "x11" =>            { code => 3  , units => 'TH/s'  , port => 3336 }
  , "x11gost" =>        { code => 26 , units => 'GH/s'  , port => 3359 }
  , "x13" =>            { code => 4  , units => 'GH/s'  , port => 3337 }
  , "x15" =>            { code => 6  , units => 'GH/s'  , port => 3339 }
  , "scrypt" =>         { code => 0  , units => 'TH/s'  , port => 3333 }
);

our %algos_by_number = (
    0 =>  "scrypt"
  , 1 =>  "sha256"
  , 2 =>  "scryptnf"
  , 3 =>  "x11"
  , 4 =>  "x13"
  , 5 =>  "keccak"
  , 6 =>  "x15"
  , 7 =>  "nist5"
  , 8 =>  "neoscrypt"
  , 9 =>  "lyra2re"
  , 10 => "whirlpoolx"
  , 11 => "qubit"
  , 12 => "quark"
  , 13 => "axiom"
  , 14 => "lyra2rev2"
  , 15 => "scryptjanenf16"
  , 16 => "blake256r8"
  , 17 => "blake256r14"
  , 18 => "blake256r8vnl"
  , 19 => "hodl"
  , 20 => "daggerhashimoto"
  , 21 => "decred"
  , 22 => "cryptonight"
  , 23 => "lbry"
  , 24 => "equihash"
  , 25 => "pascal"
  , 26 => "x11gost"
  , 27 => "sia"
  , 28 => "blake2s"
);

sub niceport
{
  my $algo = $_[0];

  $algos{$algo}{port}
}

sub nicecurl
{
  my $method = shift;
  my @params = @_;

  my $res = curl("https://api.nicehash.com/api", method => $method, @params);

  my $js;
  eval {
    $js = decode_json($res) or die $!;
  };
  if($@)
  {
    print STDERR "NICEHASH API QUERY FAILURE (use -v to see the error)\n";

    if($::verbose)
    {
      print STDERR (Dumper [ "nicehash response", $@, $res ]);
    }

    return undef;
  }

  $$js{result}
}

# normalize btc/units/day -> btc/mh/day
sub normalize_price
{
  my ($units, $price) = @_;

  $units = lc($units);
  substr($units, -2) = "" if substr($units, -2) eq "/s";
  substr($units, -3) = "h" if substr($units, -3) eq "sol";

  # downscale to mh
  if($units eq 'ph')
  {
    $price /= 1000;
    $units = 'th';
  }
  if($units eq 'th')
  {
    $price /= 1000;
    $units = 'gh';
  }
  if($units eq 'gh')
  {
    $price /= 1000;
    $units = 'mh';
  }

  # upscale to mh
  if($units eq 'h')
  {
    $price *= 1000;
    $units = 'kh';
  }
  if($units eq 'kh')
  {
    $price *= 1000;
    $units = 'mh';
  }

  $price;
}

# normalize units/s -> mh/s
sub normalize_hashrate
{
  my ($units, $price) = @_;

  $units = lc($units);
  substr($units, -2) = "" if substr($units, -2) eq "/s";
  substr($units, -3) = "h" if substr($units, -3) eq "sol";

  # downscale to mh
  if($units eq 'ph')
  {
    $price *= 1000;
    $units = 'th';
  }
  if($units eq 'th')
  {
    $price *= 1000;
    $units = 'gh';
  }
  if($units eq 'gh')
  {
    $price *= 1000;
    $units = 'mh';
  }

  # upscale to mh
  if($units eq 'h')
  {
    $price /= 1000;
    $units = 'kh';
  }
  if($units eq 'kh')
  {
    $price /= 1000;
    $units = 'mh';
  }

  $price;
}

sub normalize_algo_price
{
  my ($algo, $price) = @_;

  my $config = $algos{$algo};
  my $units = lc($$config{units});

  normalize_price($units, $price)
}

sub stats_global
{
  my ($api_method, $region) = @_;
  my %rates;

  my $js = nicecurl($api_method, location => $regions{$region}{code});
  return undef unless $js;

  for my $offer (@{$$js{stats}})
  {
    my $algonum = $$offer{algo};
    my $algoname = $algos_by_number{$algonum};

    $rates{$algoname} = normalize_algo_price($algoname, $$offer{price});
  }

  \%rates;
}

sub stats_global_current
{
  stats_global('stats.global.current', 'usa')
}

#
# this nicehash api doesnt report accurate accepted rate until the miner has
# been submitting shares over a period of 5 minutes
#
# in addition the data for the current algorithm seems to reflect only the
# previous 5 minutes
#
sub current_performance
{
  my ($addr, $algo, $market, $started) = @_;

  my $dur = time() - $started;
  if((time() - $started) < (60 * 5))
  {
    return { price => 0, speed => 0 }; # no point
  }

  my $js = nicecurl('stats.provider.ex'
    , addr => $addr
    , from => (time() - (60 * 5))
  );
  return undef if not $js;

  for my $result (@{$$js{current}})
  {
    if($$result{algo} == $algos{$algo}{code})
    {
      my $price = normalize_price($$result{suffix}, $$result{profitability});
      my $accepted = 0;
      $accepted = $$result{data}[0]{"a"} if $#{$$result{data}} >= 0;
      $accepted = normalize_hashrate($$result{suffix}, $accepted) if $accepted;

      return { price => $price, speed => $accepted || 0 };
    }
  }

  return undef;
}

# returns true if all algos were updated
sub orders_summarize
{
  my ($region, $rates, $opportunities) = @_;

  my $failures = 0;

  for my $algo (keys %algos)
  {
    my $js = nicecurl('orders.get', location => $regions{$region}{code}, algo => $algos{$algo}{code});
    if(!$js)
    {
      $failures++;
      sleep 3;
      next;
    }

    my @orders = sort { $$a{price} <=> $$a{price} } @{$$js{orders}};

    my $total_accepted_speed = 0;
    for my $order (@orders)
    {
      $total_accepted_speed += $$order{accepted_speed};
    }

    # opportunity in switching
    my $opportunity_price = 0;
    my $opportunity_speed = 0;
    for my $order (@orders)
    {
      my $remaining_speed = ($total_accepted_speed * .1) - $opportunity_speed;
      my $available_speed;
      if($$order{limit_speed} == 0)
      {
        $available_speed = $remaining_speed;
      }
      else
      {
        $available_speed = $$order{limit_speed} - $$order{accepted_speed};
        $available_speed = $remaining_speed if $available_speed > $remaining_speed;
      }

      $available_speed = 0 if $available_speed < 0;
      $opportunity_speed += $available_speed;
      $opportunity_price += $$order{price} * $available_speed;

      last if $opportunity_speed >= ($total_accepted_speed * .1);
    }

    my $price = 0;
    if($total_accepted_speed && ($opportunity_speed >= ($total_accepted_speed * .1)))
    {
      $price = $opportunity_price / $opportunity_speed;
    }
    $price = normalize_algo_price($algo, $price);

    my $size_pct = 0;
    $size_pct = $opportunity_speed / $total_accepted_speed if $total_accepted_speed;
    $size_pct *= 100;

    $$opportunities{$algo}{total} = $total_accepted_speed;
    $$opportunities{$algo}{size} = $opportunity_speed;
    $$opportunities{$algo}{size_pct} = $size_pct * 100;
    $$opportunities{$algo}{price} = $price;

    # average price paid per hashrate
    my $sum = 0;
    for my $order (@orders)
    {
      $sum += $$order{price} * $$order{accepted_speed};
    }

    $price = 0;
    $price = $sum / $total_accepted_speed if $total_accepted_speed;
    $$rates{$algo} = normalize_algo_price($algo, $price);
  }

  !$failures
}

1
