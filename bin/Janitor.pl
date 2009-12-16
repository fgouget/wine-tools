#!/usr/bin/perl -Tw
#
# Janitorial tasks
# Run this from crontab once per day, e.g.
# 17 1 * * * /usr/lib/winetestbot/bin/Janitor.pl
#
# Copyright 2009 Ge van Geldorp
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA

use strict;

my $Dir;
sub BEGIN
{
  $0 =~ m=^(.*)/[^/]*$=;
  $Dir = $1;
}
use lib "$Dir/../lib";

use WineTestBot::Config;
use WineTestBot::Jobs;
use WineTestBot::Log;

$ENV{PATH} = "/usr/bin:/bin";
delete $ENV{ENV};

my $DeleteBefore = time() - 7 * 86400;
my $Jobs = CreateJobs();
foreach my $JobKey (@{$Jobs->GetKeys()})
{
  my $Job = $Jobs->GetItem($JobKey);
  if (defined($Job->Ended) && $Job->Ended < $DeleteBefore)
  {
    LogMsg "Janitor: deleting job ", $Job->Id, "\n";
    system "rm", "-rf", "$DataDir/jobs/" . $Job->Id;
    my $ErrMessage = $Jobs->DeleteItem($Job);
    if (defined($ErrMessage))
    {
      LogMsg "Janitor: ", $ErrMessage, "\n";
    }
  }
}
