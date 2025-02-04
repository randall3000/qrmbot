#!/usr/bin/perl -w
#
# Geocoding utility functions.  Uses Google API.
#
# 2-clause BSD license.
# Copyright (c) 2018, 2019, 2020 molo1134@github. All rights reserved.

package Location;
require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(argToCoords qthToCoords coordToGrid geolocate gridToCoord distBearing coordToTZ getGeocodingAPIKey coordToElev azToNEWS pathProfile rangeAndBearing);

use utf8;
use Math::Trig;
use Math::Trig 'great_circle_distance';
use Math::Trig 'great_circle_bearing';
use Math::Trig 'great_circle_destination';
use URI::Escape;
use JSON qw( decode_json );
use Time::HiRes qw(usleep);

sub getGeocodingAPIKey {
  my $apikeyfile = $ENV{'HOME'} . "/.googleapikeys";
  if (-e ($apikeyfile)) {
    do $apikeyfile;
  } else {
    print "error: unable to read file $apikeyfile\n";
  }
  return $geocodingapikey;
}

sub gridToCoord {
  my $gridstr = shift;

  if (not $gridstr =~ /^[A-R]{2}[0-9]{2}([A-X]{2})?/i ) {
    print "\ninvalid grid\n";
    return undef;
  }

  my @grid = split (//, uc($gridstr));

  if ($#grid < 3) {
    return undef;
  }

  my $lat;
  my $lon;
  my $formatter;

  $lon = ((ord($grid[0]) - ord('A')) * 20) - 180;
  $lat = ((ord($grid[1]) - ord('A')) * 10) - 90;
  $lon += ((ord($grid[2]) - ord('0')) * 2);
  $lat += ((ord($grid[3]) - ord('0')) * 1);

  if ($#grid >= 5) {
    $lon += ((ord($grid[4])) - ord('A')) * (5/60);
    $lat += ((ord($grid[5])) - ord('A')) * (5/120);
    # move to center of subsquare
    $lon += (5/120);
    $lat += (5/240);
    # not too precise
    $formatter = "%.4f";
  } else {
    # move to center of square
    $lon += 1;
    $lat += 0.5;
    # even less precise
    $formatter = "%.1f";
  }

  # not too precise
  $lat = sprintf($formatter, $lat);
  $lon = sprintf($formatter, $lon);

  return join(',', $lat, $lon);
}

sub coordToGrid {
  my $lat = shift;
  my $lon = shift;
  my $grid = "";

  $lon = $lon + 180;
  $lat = $lat + 90;

  $grid .= chr(ord('A') + int($lon / 20));
  $grid .= chr(ord('A') + int($lat / 10));
  $grid .= chr(ord('0') + int(($lon % 20)/2));
  $grid .= chr(ord('0') + int(($lat % 10)/1));
  $grid .= chr(ord('a') + int(($lon - (int($lon/2)*2)) / (5/60)));
  $grid .= chr(ord('a') + int(($lat - (int($lat/1)*1)) / (2.5/60)));

  return $grid;
}

sub qthToCoords {
  my $place = uri_escape_utf8(shift);
  my $lat = undef;
  my $lon = undef;
  my $apikey = getGeocodingAPIKey();
  my $url = "https://maps.googleapis.com/maps/api/geocode/xml?address=$place&sensor=false&key=$apikey";

  return undef if not defined $apikey;

  my $tries = 0;
  my $maxtries = 10;

  while ($tries < $maxtries and (not defined $lat or not defined $lon)) {
    open (HTTP, '-|', "curl --stderr - -N -k -s -L --max-time 5 '$url'");
    binmode(HTTP, ":utf8");
    GET: while (<HTTP>) {
      #print;
      chomp;
      if (/OVER_QUERY_LIMIT/) {
	my $msg = <HTTP>;
	$msg =~ s/^\s*<error_message>(.*)<\/error_message>/$1/;
	print "error: over query limit: $msg\n" if $tries + 1 == $maxtries;
	usleep 1000 if $tries + 1 < $maxtries;
	last GET;
      }
      if (/<lat>([+-]?\d+.\d+)<\/lat>/) {
	$lat = $1;
      }
      if (/<lng>([+-]?\d+.\d+)<\/lng>/) {
	$lon = $1;
      }
      if (defined($lat) and defined($lon)) {
	last GET;
      }
    }
    close HTTP;

    $tries++;
  }

  if (defined($lat) and defined($lon)) {
    return "$lat,$lon";
  } else {
    return undef;
  }
}

sub geolocate {
  my $lat = shift;
  my $lon = shift;
  my $apikey = getGeocodingAPIKey();
  return undef if not defined $apikey;

  $lat =~ s/\s//g;
  $lon =~ s/\s//g;

  my $url = "https://maps.googleapis.com/maps/api/geocode/xml?latlng=$lat,$lon&sensor=false&key=$apikey";

  my $newResult = 0;
  my $getnextaddr = 0;
  my $addr = undef;
  my $type = undef;

  my %results;
  my $tries = 0;
  my $maxtries = 10;

  RESTART:

  #print "$url\n";
  my $count = -1;
  open (HTTP, '-|', "curl --stderr - -N -k -s -L --max-time 5 '$url'");
  binmode(HTTP, ":utf8");
  local $/; # read entire output -- potentially memory hungry
  my $xml = <HTTP>;
  close(HTTP);

  foreach $_ (split /\n/,$xml) {
    $count++;
    #print "$count $_\n";

    if (/OVER_QUERY_LIMIT/) {
      #print "warning: over query limit\n" unless defined($raw) and $raw == 1;
      print "error: over query limit\n" if $tries++ > $maxtries;
      return undef if $tries > $maxtries;
      usleep(1000);
      goto RESTART;
    }

    last if /ZERO_RESULTS/;

    if (/<result>/) {
      $newResult = 1;
      next;
    }

    if ($newResult == 1 and /<type>([^<]+)</) {
      $type = $1;
      $getnextaddr = 1;
      $newResult = 0;
      next;
    }

    if ($getnextaddr == 1 and /<formatted_address>([^<]+)</) {
      $results{$type} = $1;
      #print "$type => $1\n";
      $getnextaddr = 0;
      next;
    }
  }

  if (defined($results{"neighborhood"})) {
    $addr = $results{"neighborhood"};
  } elsif (defined($results{"locality"})) {
    $addr = $results{"locality"};
  } elsif (defined($results{"administrative_area_level_3"})) {
    $addr = $results{"administrative_area_level_3"};
  } elsif (defined($results{"postal_town"})) {
    $addr = $results{"postal_town"};
  } elsif (defined($results{"political"})) {
    $addr = $results{"political"};
  } elsif (defined($results{"postal_code"})) {
    $addr = $results{"postal_code"};
  } elsif (defined($results{"administrative_area_level_2"})) {
    $addr = $results{"administrative_area_level_2"};
  } elsif (defined($results{"administrative_area_level_1"})) {
    $addr = $results{"administrative_area_level_1"};
  } elsif (defined($results{"country"})) {
    $addr = $results{"country"};
  } elsif (defined($results{"sublocality"})) {
    $addr = $results{"sublocality"};
  } elsif (defined($results{"sublocality_level_3"})) {
    $addr = $results{"sublocality_level_3"};
  } elsif (defined($results{"sublocality_level_4"})) {
    $addr = $results{"sublocality_level_4"};
  }

  return $addr;
}

sub argToCoords {
  my $arg = shift;
  my $type;

  if ($arg =~ /^(grid:)? ?([A-R]{2}[0-9]{2}([a-x]{2})?)/i) {
    $arg = $2;
    $type = "grid";
  } elsif ($arg =~ /^(geo:)? ?([-+]?\d+(.\d+)?,\s?[-+]?\d+(.\d+)?)/i) {
    $arg = $2;
    $type = "geo";
  } else {
    $type = "qth";
  }

  my $lat = undef;
  my $lon = undef;
  my $grid = undef;

  if ($type eq "grid") {
    $grid = $arg;
  } elsif ($type eq "geo") {
    ($lat, $lon) = split(',', $arg);
  } elsif ($type eq "qth") {
    my $ret = qthToCoords($arg);
    if (!defined($ret)) {
      #print "'$arg' not found.\n";
      #exit $::exitnonzeroonerror;
      return undef;
    }
    ($lat, $lon) = split(',', $ret);
  }

  if (defined($grid)) {
    ($lat, $lon) = split(',', gridToCoord(uc($grid)));
  }

  return join(',', $lat, $lon);
}

sub distBearing {
  my $lat1 = shift;
  my $lon1 = shift;
  my $lat2 = shift;
  my $lon2 = shift;

  my @origin = NESW($lon1, $lat1);
  my @foreign = NESW($lon2, $lat2);

  my ($dist, $bearing);

  # disable "experimental" warning on smart match operator use
  no if $] >= 5.018, warnings => "experimental::smartmatch";

  if (@origin ~~ @foreign) {	  # smart match operator - equality comparison
    $dist = 0;
    $bearing = 0;
  } else {
    $dist = great_circle_distance(@origin, @foreign, 6378.1);
    $bearing = rad2deg(great_circle_bearing(@origin, @foreign));
  }

  return ($dist, $bearing);
}

# given the origin coordates, find the coordinates at the given range (in km)
# and bearing (in degrees)
sub rangeAndBearing {
  my $lat = shift;
  my $lon = shift;
  my $range = shift;
  my $bearing = shift;

  my @origin = NESW($lon, $lat);

  my $diro = deg2rad($bearing);
  my $distance = $range / 6378.1; # in radians

  ($thetad, $phid, $dird) = great_circle_destination(@origin, $diro, $distance);
  my ($lon2, $lat2) = (rad2deg($thetad), rad2deg($phid)); # note order

  return ($lat2, $lon2);
}

# Notice the 90 - latitude: phi zero is at the North Pole.
# Example: my @London = NESW( -0.5, 51.3); # (51.3N 0.5W)
# Example: my @Tokyo  = NESW(139.8, 35.7); # (35.7N 139.8E)
sub NESW {
  deg2rad($_[0]), deg2rad(90 - $_[1])
}

sub coordToTZ {
  my $lat = shift;
  my $lon = shift;
  my $apikey = getGeocodingAPIKey();
  return undef if not defined $apikey;

  my $now = time();
  my $url = "https://maps.googleapis.com/maps/api/timezone/json?location=$lat,$lon&timestamp=$now&key=$apikey";

  my ($dstoffset, $rawoffset, $zoneid, $zonename);

  open (HTTP, '-|', "curl --stderr - -N -k -s -L --max-time 5 '$url'");
  binmode(HTTP, ":utf8");
  while (<HTTP>) {

    # {
    #    "dstOffset" : 3600,
    #    "rawOffset" : -18000,
    #    "status" : "OK",
    #    "timeZoneId" : "America/New_York",
    #    "timeZoneName" : "Eastern Daylight Time"
    # }

    if (/"(\w+)" : (-?\d+|"[^"]*")/) {
      my ($k, $v) = ($1, $2);
      $v =~ s/^"(.*)"$/$1/;
      #print "$k ==> $v\n";
      if ($k eq "status" and $v ne "OK") {
	return undef;
      }
      $dstOffset = $v if $k eq "dstOffset";
      $rawOffset = $v if $k eq "rawOffset";
      $zoneid = $v if $k eq "timeZoneId";
      $zonename = $v if $k eq "timeZoneName";
    }
  }
  close(HTTP);

  return $zoneid;
}

sub coordToElev {
  my $lat = shift;
  my $lon = shift;
  my $apikey = getGeocodingAPIKey();
  return undef if not defined $apikey;

  $lat =~ s/\s//g;
  $lon =~ s/\s//g;

  my $url = "https://maps.googleapis.com/maps/api/elevation/json?locations=$lat,$lon&key=$apikey";

  my ($elev, $res);
  open (HTTP, '-|', "curl --stderr - -N -k -s -L --max-time 5 '$url'");
  binmode(HTTP, ":utf8");
  while (<HTTP>) {
    # {
    #    "results" : [
    #       {
    #          "elevation" : 1608.637939453125,
    #          "location" : {
    #             "lat" : 39.73915360,
    #             "lng" : -104.98470340
    #          },
    #          "resolution" : 4.771975994110107
    #       }
    #    ],
    #    "status" : "OK"
    # }
    if (/"(\w+)" : (-?\d+(\.\d+)?|"[^"]*")/) {
      my ($k, $v) = ($1, $2);
      $v =~ s/^"(.*)"$/$1/;
      #print "$k ==> $v\n";
      if ($k eq "status" and $v ne "OK") {
	return undef;
      }
      $elev = $v if $k eq "elevation";
      $res = $v if $k eq "resolution";
    }
  }
  close(HTTP);

  return $elev;
}

sub pathProfile {
  my $lat1 = shift;
  my $lon1 = shift;
  my $lat2 = shift;
  my $lon2 = shift;
  my $samples = shift;

  my $apikey = getGeocodingAPIKey();
  return undef if not defined $apikey;

  $lat1 =~ s/\s//g;
  $lon1 =~ s/\s//g;
  $lat2 =~ s/\s//g;
  $lon2 =~ s/\s//g;
  $samples = 70 if not defined $samples;

  my $url = "https://maps.googleapis.com/maps/api/elevation/json?path=${lat1},${lon1}|${lat2},${lon2}&samples=${samples}&key=$apikey";

  open (HTTP, '-|', "curl --stderr - -N -k -s -L --max-time 15 '$url'");
  binmode(HTTP, ":utf8");
  local $/; # read entire output -- potentially memory hungry
  my $json = <HTTP>;
  #print "$json\n";
  my $j = decode_json($json);

  my @r;
  foreach my $e (@{$j->{results}}) {
    #print $e->{elevation}, "\n";
    push @r, $e->{elevation};
  }

  return @r;
}

sub azToNEWS {
  my $az = shift;
  return undef if not defined $az;
  return "N"   if $az >= 0.0 and $az < 11.25;
  return "NNE" if $az < 33.75;
  return "NE"  if $az < 56.25;
  return "ENE" if $az < 78.75;
  return "E"   if $az < 101.25;
  return "ESE" if $az < 123.75;
  return "SE"  if $az < 146.25;
  return "SSE" if $az < 168.75;
  return "S"   if $az < 191.25;
  return "SSW" if $az < 213.75;
  return "SW"  if $az < 236.25;
  return "WSW" if $az < 258.75;
  return "W"   if $az < 281.25;
  return "WNW" if $az < 303.75;
  return "NW"  if $az < 326.25;
  return "NNW" if $az < 348.75;
  return "N"   if $az <= 360.0;
  return undef;
}

