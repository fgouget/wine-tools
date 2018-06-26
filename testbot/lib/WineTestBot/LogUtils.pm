# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2018 Francois Gouget
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

package WineTestBot::LogUtils;

=head1 NAME

WineTestBot::LogUtils - Provides functions to parse task logs

=cut


use Exporter 'import';
our @EXPORT = qw(GetLogLineCategory ParseTaskLog);


#
# Task log parser
#

=pod
=over 12

=item C<ParseTaskLog()>

Returns ok if the task was successful and an error code otherwise.

=back
=cut

sub ParseTaskLog($$)
{
  my ($FileName, $ResultPrefix) = @_;

  if (open(my $LogFile, "<", $FileName))
  {
    my $Result;
    foreach my $Line (<$LogFile>)
    {
      chomp $Line;
      if ($Line =~ /^$ResultPrefix: ok$/)
      {
        $Result ||= "ok";
      }
      elsif ($Line =~ /^$ResultPrefix: Patch failed to apply$/)
      {
        $Result = "badpatch";
        last; # Should be the last and most specific message
      }
      elsif ($Line =~ /^$ResultPrefix: /)
      {
        $Result = "failed";
      }
    }
    close($LogFile);
    return $Result || "missing";
  }
  return "nolog:Unable to open the task log for reading: $!";
}


#
# Log querying and formatting
#

=pod
=over 12

=item C<GetLogLineCategory()>

Identifies the category of the given log line: an error message, a todo, just
an informational message or none of these. The category can then be used to
decide whether to hide the line or, on the contrary, highlight it.

=back
=cut

sub GetLogLineCategory($)
{
  my ($Line) = @_;

  if ($Line =~ /: Test marked todo: /)
  {
    return "todo";
  }
  if ($Line =~ /: Tests skipped: / or
      $Line =~ /^\w+:\w+ skipped /)
  {
    return "skip";
  }
  if ($Line =~ /: Test (?:failed|succeeded inside todo block): / or
      $Line =~ /Fatal: test .* does not exist/ or
      $Line =~ / done \(258\)/ or
      $Line =~ /: unhandled exception [0-9a-fA-F]{8} at / or
      $Line =~ /^Unhandled exception: / or
      # Git errors
      $Line =~ /^CONFLICT / or
      $Line =~ /^error: patch failed:/ or
      $Line =~ /^error: corrupt patch / or
      # Build errors
      $Line =~ /: error: / or
      $Line =~ /^Makefile:[0-9]+: recipe for target .* failed$/ or
      $Line =~ /^(?:Build|Reconfig|Task): (?!ok)/ or
      # Typical perl errors
      $Line =~ /^Use of uninitialized value/)
  {
    return "error";
  }
  if ($Line =~ /^\+ \S/ or
      $Line =~ /^\w+:\w+ start / or
      # Build messages
      $Line =~ /^(?:Build|Reconfig|Task): ok/)
  {
    return "info";
  }

  return "none";
}

1;
