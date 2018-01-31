# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2009-2011 Ge van Geldorp
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

package WineTestBot::WineTestBotItem;

=head1 NAME

WineTestBot::WineTestBotItem - Base item class for WineTestBot

=cut

use ObjectModel::BackEnd;
use ObjectModel::Item;
use WineTestBot::Config;

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(ObjectModel::Item Exporter);

sub GetBackEnd($)
{
  #my ($self) = @_;
  return $ActiveBackEnds{'WineTestBot'};
}


package WineTestBot::WineTestBotCollection;

=head1 NAME

WineTestBot::WineTestBotCollection - Base collection class for WineTestBot

=cut

use ObjectModel::BackEnd;
use ObjectModel::Item;
use WineTestBot::Config;

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(ObjectModel::Collection Exporter);

sub GetBackEnd($)
{
  #my ($self) = @_;
  return $ActiveBackEnds{'WineTestBot'};
}

1;
