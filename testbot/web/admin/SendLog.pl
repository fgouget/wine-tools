# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Sends an excerpt of the TestBot Engine log
#
# Copyright 2017 Francois Gouget
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

use HTTP::Date;

use Apache2::Const -compile => qw(REDIRECT);
use CGI;
use CGI::Cookie;
use URI::Escape;
use WineTestBot::Config;
use WineTestBot::CGI::Sessions;
use WineTestBot::Log;


sub GetStartPosition($$)
{
  my ($Log, $Hours) = @_;

  # The log file can be pretty long so do a binary search to figure out where
  # the oldest log line less than $Hours old is.
  my $Cutoff = time() - 3600 * $Hours;
  my $Size = (stat($Log))[7];
  my ($Min, $Max) = (0, $Size);
  while ($Min < $Max)
  {
    my $Middle = int(($Min + $Max) / 2);
    seek($Log, $Middle, 0);

    # Ignore the first line which we assume is going to be incomplete (even
    # if by chance it start with a timestamp there is no way to know if that
    # timestamp is at the beginning of the line). Also adjust $Middle so it
    # always points to the start of a line.
    my $Line = <$Log>;
    $Middle += length($Line);
    if ($Middle >= $Size)
    {
      # There is no line less than $Hours old so it would make sense to
      # return $Size. But instead return $Min so the administrator at
      # least sees the last line.
      return ($Min, 0);
    }
    if ($Middle >= $Max)
    {
      # There is only one line between $Min and $Max. Determine whether to
      # include it or not.
      $Middle = $Min;
      seek($Log, $Middle, 0);
    }
    my $Current = $Middle;
    while ($Line = <$Log>)
    {
      # Note that the log file may have lines with no timestamp
      if ($Line =~ /^(\w{3} \w{3} [0-9 ]\d \d{2}:\d{2}:\d{2} \d{4}) /)
      {
        my $Time = str2time($1);
        if ($Time < $Cutoff)
        {
          # This line is too old
          $Current += length($Line);
          if ($Current >= $Size)
          {
            # See the $Middle == $Size comment. Note that this may return more
            # than one line.
            return ($Min, 0);
          }
          $Min = $Current;
        }
        else
        {
          # Consider that lines with no timestamp are less than $Hours old too
          $Max = $Middle;
        }
        last;
      }
      $Current += length($Line);
      if ($Current >= $Max)
      {
        # Consider that lines with no timestamp are less than $Hours old too
        $Max = $Middle;
        last;
      }
    }
    return $Min if (!defined $Line);
  }
  return ($Min, 1);
}

sub PrintLog($)
{
  my ($Request) = @_;

  my $CGIObj = CGI->new($Request);
  my $Hours = $CGIObj->param("Hours");
  if (!defined $Hours or $Hours !~ /^(\d\d?)$/)
  {
      $Request->headers_out->set("Location", "/");
      $Request->status(Apache2::Const::REDIRECT);
      exit;
  }
  $Hours = $1;

  # Text file
  $Request->content_type("text/plain");

  my $Log = OpenLog();
  if (defined $Log)
  {
    binmode($Log);
    if ($Hours > 0)
    {
      my ($Position, $Found) = GetStartPosition($Log, $Hours);
      if (!$Found)
      {
        print "There is no log entry less than $Hours hour(s) old.\n";
        print "Here are the last few lines:\n";
      }
      seek($Log, $Position, 0);
    }

    binmode(STDOUT);
    while (1)
    {
      my $Block;
      my $Len = sysread($Log, $Block, 16384);
      last if (!$Len);
      print $Block;
    }
    close($Log);
  }
  else
  {
    print "Could not open the log file!\n";
  }
}

my $Request = shift;

my %Cookies = CGI::Cookie->fetch($Request);
my $IsAdmin;
if (defined $Cookies{"SessionId"})
{
  my $Session = CreateSessions()->GetItem($Cookies{"SessionId"}->value);
  $IsAdmin = $Session->User->HasRole("admin") if ($Session);

}
if (!$IsAdmin)
{
  $Request->headers_out->set("Location", "/Login.pl?Target=" . uri_escape($ENV{"REQUEST_URI"}));
  $Request->status(Apache2::Const::REDIRECT);
  exit;
}

PrintLog($Request);

exit;
