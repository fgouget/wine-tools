# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# VM list page
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

package VMsListPage;

use ObjectModel::CGI::CollectionPage;
use WineTestBot::VMs;

@VMsListPage::ISA = qw(ObjectModel::CGI::CollectionPage);

sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->SUPER::_initialize($Request, $RequiredRole, CreateVMs());
}

sub DisplayProperty($$$)
{
  my ($self, $CollectionBlock, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();

  return $PropertyName eq "Name" || $PropertyName eq "Type" ||
         $PropertyName eq "Role" || $PropertyName eq "Status" ||
         $PropertyName eq "Description";
}

sub SortKeys($$$)
{
  my ($self, $CollectionBlock, $Keys) = @_;

  return $self->{Collection}->SortKeysBySortOrder($Keys);
}

sub OnItemAction($$$$)
{
  my ($self, $CollectionBlock, $Item, $Action) = @_;

  if ($Action eq "Delete")
  {
    $Item->Role("deleted");
    my ($ErrProperty, $ErrMessage) = $Item->Save();
    return ! defined($ErrMessage);
  }

  return $self->SUPER::OnItemAction($CollectionBlock, $Item, $Action);
}

package main;

my $Request = shift;

my $VMsListPage = VMsListPage->new($Request, "admin");
$VMsListPage->GeneratePage();
