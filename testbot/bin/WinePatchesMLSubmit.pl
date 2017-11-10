#!/usr/bin/perl -Tw
# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
#
# This script expects to receive a wine-devel email on stdin and submits it
# to WineTestBot for testing. It is meant to be called from a tool such as
# procmail.
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

sub BEGIN
{
  if ($0 !~ m=^/=)
  {
    # Turn $0 into an absolute path so it can safely be used in @INC
    require Cwd;
    $0 = Cwd::cwd() . "/$0";
  }
  if ($0 =~ m=^(/.*)/[^/]+/[^/]+$=)
  {
    $::RootDir = $1;
    unshift @INC, "$::RootDir/lib";
  }
}

use File::Copy;
use WineTestBot::Config;
use WineTestBot::Utils;
use WineTestBot::Engine::Notify;
use WineTestBot::Log;

# Store the message in the staging dir
my ($fh, $FileName) = OpenNewFile("$DataDir/staging", "_wine-patches");
if (!$fh)
{
  LogMsg "Could not create a staging file: $!\n";
  exit 1;
}
if (!copy(\*STDIN, $fh))
{
  LogMsg "Could not copy the email to '$FileName': $!\n";
  close($fh);
  exit 1;
}
close($fh);

# Notify the Engine of the new message
my $ErrMessage = WinePatchMLSubmission();
if (defined $ErrMessage)
{
  # The Engine will pick up the email later so return success anyway.
  # But still log the issue so it can be checked out.
  LogMsg "$ErrMessage\n"
}

exit 0;
