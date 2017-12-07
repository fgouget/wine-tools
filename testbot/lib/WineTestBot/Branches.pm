# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Copyright 2009 Ge van Geldorp
# Copyright 2012 Francois Gouget
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

package WineTestBot::Branch;

=head1 NAME

WineTestBot::Branch - Describes a Wine branch

=cut

use WineTestBot::WineTestBotObjects;
use WineTestBot::Config;

use vars qw (@ISA @EXPORT);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotItem Exporter);

sub InitializeNew($$)
{
  my ($self, $Collection) = @_;

  $self->IsDefault(!1);
  $self->SUPER::InitializeNew($Collection);
}

package WineTestBot::Branches;

=head1 NAME

WineTestBot::Branches - A collection of WineTestBot::Branch objects

=cut

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::PropertyDescriptor;
use WineTestBot::WineTestBotObjects;

use vars qw (@ISA @EXPORT @PropertyDescriptors);

require Exporter;
@ISA = qw(WineTestBot::WineTestBotCollection Exporter);
@EXPORT = qw(&CreateBranches);

sub GetDefaultBranch($)
{
  my ($self) = @_;

  foreach my $Branch (@{$self->GetItems()})
  {
    return $Branch if ($Branch->IsDefault);
  }

  return undef;
}

BEGIN
{
  @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("Name",      "Branch name",          1,  1, "A", 20),
    CreateBasicPropertyDescriptor("IsDefault", "Default branch",       !1,  1, "B",  1),
  );
}

sub MultipleBranchesPresent($)
{
  my ($self) = @_;
  
  return 1 < scalar(@{$self->GetKeys()});
}

sub CreateItem($)
{
  my ($self) = @_;

  return WineTestBot::Branch->new($self);
}

sub CreateBranches(;$)
{
  my ($ScopeObject) = @_;
  return WineTestBot::Branches->new("Branches", "Branches", "Branch",
                                    \@PropertyDescriptors, $ScopeObject);
}

1;
