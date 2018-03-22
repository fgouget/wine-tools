# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
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

package WineTestBot::Log;

=head1 NAME

WineTestBot::Log - Logging

=cut

use WineTestBot::Config;
use WineTestBot::Utils;

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(&LogMsg &OpenLog &Time &Elapsed &PrettyElapsed);

my $logfile;
my $logprefix;
sub LogMsg(@)
{
  if (!defined $logfile)
  {
    require File::Basename;
    $logprefix = File::Basename::basename($0);
    $logprefix =~ s/\.[^.]*$//;
    my $oldumask = umask(002);
    if (!open($logfile, ">>", "$LogDir/log"))
    {
      print STDERR "$logprefix:warning: could not open '$LogDir/log' for writing: $!\n";
      open($logfile, ">>&=", 2);
    }
    umask($oldumask);

    # Flush after each print
    my $tmp=select($logfile);
    $| = 1;
    select($tmp);
  }
  print $logfile scalar localtime, " ", $logprefix, "[$$]: ", @_ if ($logfile);
}

sub OpenLog()
{
  my $Handle;
  return open($Handle, "<", "$LogDir/log") ? $Handle : undef;
}

=pod
=over 12

=item C<SetupRedirects()>

This redirects stderr so it writes to our log. This is typically called before
exec()-ing external tools so their error messages are not lost.

=back
=cut

sub SetupRedirects()
{
  if (defined $logfile)
  {
    if (open(STDERR, ">>&", $logfile))
    {
      # Make sure stderr still flushes after each print
      my $tmp=select(STDERR);
      $| = 1;
      select($tmp);
    }
    else
    {
      LogMsg "unable to redirect stderr to '$logfile': $!\n";
    }
  }
}

my $HiResTime;
sub Time()
{
  local $@;
  $HiResTime = eval { require Time::HiRes } if (!defined $HiResTime);
  return eval { Time::HiRes::time() } if ($HiResTime);
  return time();
}

sub Elapsed($)
{
    my ($Start) = @_;
    return sprintf("%0.2f", Time()-$Start);
}

sub PrettyElapsed($)
{
    my ($Start) = @_;
    return DurationToString(Time()-$Start);
}

1;
