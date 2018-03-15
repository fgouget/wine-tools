# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# WineTestBot engine events
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

package WineTestBot::Engine::Events;

=head1 NAME

WineTestBot::Engine::Events - Engine events

=cut

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(&AddEvent &DeleteEvent &EventScheduled &RunEvents);

my %Events;

sub AddEvent($$$$)
{
  my ($Name, $Timeout, $Repeat, $HandlerFunc) = @_;

  $Events{$Name} = {Expires => time() + $Timeout,
                    Timeout => $Timeout,
                    Repeat => $Repeat,
                    HandlerFunc => $HandlerFunc};
}

sub DeleteEvent($)
{
  my ($Name) = @_;

  delete $Events{$Name};
}

sub EventScheduled($)
{
  my ($Name) = @_;

  return defined($Events{$Name});
}

sub RunEvents()
{
  my $Now = time();
  my $Next = undef;
  foreach my $Name (keys %Events)
  {
    my $Event = $Events{$Name};
    if (defined($Event))
    {
      if ($Event->{Expires} <= $Now)
      {
        if ($Event->{Repeat})
        {
          $Event->{Expires} += $Event->{Timeout};
          if (! defined($Next) || $Event->{Expires} - $Now < $Next)
          {
            $Next = $Event->{Expires} - $Now;
          }
        }
        else
        {
          delete $Events{$Name};
        }
        &{$Event->{HandlerFunc}}();
      }
      elsif (! defined($Next) || $Event->{Expires} - $Now < $Next)
      {
        $Next = $Event->{Expires} - $Now;
      }
    }
  }

  return $Next;
}

1;
