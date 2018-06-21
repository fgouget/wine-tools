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
our @EXPORT = qw(ParseTaskLog);


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

1;
