# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# User list page
#
# Copyright 2009 Ge van Geldorp
# Copyright 2013 Francois Gouget
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

package UsersListPage;

use ObjectModel::CGI::CollectionPage;
use WineTestBot::CGI::Sessions;
use WineTestBot::Config;
use WineTestBot::Users;

@UsersListPage::ISA = qw(ObjectModel::CGI::CollectionPage);

sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->SUPER::_initialize($Request, $RequiredRole, CreateUsers());
}

sub SortKeys($$$)
{
  my ($self, $CollectionBlock, $Keys) = @_;

  my @SortedKeys = sort { $a cmp $b } @$Keys;
  return \@SortedKeys;
}

sub DisplayProperty($$$)
{
  my ($self, $CollectionBlock, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();

  return $PropertyName eq "Name" || $PropertyName eq "EMail" ||
         $PropertyName eq "Status" || $PropertyName eq "RealName";
}

sub GetActions($$)
{
  my ($self, $CollectionBlock) = @_;

  if (defined($LDAPServer))
  {
    # LDAP accounts cannot be deleted
    return [];
  }

  return $self->SUPER::GetActions($CollectionBlock);
}

sub OnAction($$$)
{
  my ($self, $CollectionBlock, $Action) = @_;

  if ($Action eq "Delete")
  {
    foreach my $UserName (@{$self->{Collection}->GetKeys()})
    {
      next if (!defined $self->GetParam($CollectionBlock->SelName($UserName)));
      my $User = $self->{Collection}->GetItem($UserName);
      $User->Status('deleted');
      my ($ErrProperty, $ErrMessage) = $User->Save();
      if (defined $ErrMessage)
      {
        $self->{ErrMessage} = $ErrMessage;
        return !1;
      }
      # Forcefully log out that user by deleting his web sessions
      DeleteSessions($User);
    }
    return 1;
  }

  return $self->SUPER::OnAction($CollectionBlock, $Action);
}


package main;

my $Request = shift;

my $UsersListPage = UsersListPage->new($Request, "admin");
$UsersListPage->GeneratePage();
