# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Branch list page
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

package BranchesListPage;

use ObjectModel::CGI::CollectionPage;
use WineTestBot::Config;
use WineTestBot::Branches;

@BranchesListPage::ISA = qw(ObjectModel::CGI::CollectionPage);

sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->SUPER::_initialize($Request, $RequiredRole, CreateBranches());
}

sub SortKeys($$$)
{
  my ($self, $CollectionBlock, $Keys) = @_;

  my @SortedKeys = sort { $a cmp $b } @$Keys;
  return \@SortedKeys;
}

package main;

my $Request = shift;

my $BranchesListPage = BranchesListPage->new($Request, "admin");
$BranchesListPage->GeneratePage();
