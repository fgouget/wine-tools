# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# User details page
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

package UserDetailsPage;

use ObjectModel::CGI::ItemPage;
use WineTestBot::CGI::Sessions;
use WineTestBot::Config;
use WineTestBot::Users;

@UserDetailsPage::ISA = qw(ObjectModel::CGI::ItemPage);

sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->SUPER::_initialize($Request, $RequiredRole, CreateUsers());
}

sub DisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();
  if (defined($LDAPServer) &&
      ($PropertyName eq "Password" || $PropertyName eq "ResetCode"))
  {
    return "";
  }

  return $self->SUPER::DisplayProperty($PropertyDescriptor);
}

sub GetActions($)
{
  my ($self) = @_;

  my @Actions;
  if (!defined $LDAPServer and $self->{Item}->WaitingForApproval())
  {
    push @Actions, "Approve";
    push @Actions, "Reject" if ($self->{Item}->Name);
  }

  push(@Actions, @{$self->SUPER::GetActions()});

  return \@Actions;
}

sub OnApprove($)
{
  my ($self) = @_;

  return !1 if (!$self->Save());
  $self->{ErrMessage} = $self->{Item}->Approve();
  return !1 if (defined $self->{ErrMessage});
  $self->RedirectToList(); # does not return
  exit;
}

sub OnReject($)
{
  my ($self) = @_;

  $self->{Item}->Status('deleted');
  ($self->{ErrField}, $self->{ErrMessage}) = $self->{Item}->Save();
  return !1 if (defined $self->{ErrMessage});
  # Forcefully log out that user by deleting his web sessions
  DeleteSessions($self->{Item});
  $self->RedirectToList(); # does not return
  exit;
}

sub OnOK($)
{
  my ($self) = @_;

  return !1 if (!$self->Save());
  if ($self->{Item}->Status ne 'active')
  {
    # Forcefully log out that user by deleting his web sessions
    DeleteSessions($self->{Item});
  }
  $self->RedirectToList(); # does not return
  exit;
}

sub OnAction($$)
{
  my ($self, $Action) = @_;

  if ($Action eq "Approve")
  {
    return $self->OnApprove();
  }
  elsif ($Action eq "Reject")
  {
    return $self->OnReject();
  }
  elsif ($Action eq "OK")
  {
    return $self->OnOK();
  }

  return $self->SUPER::OnAction($Action);
}

package main;

my $Request = shift;

my $UserDetailsPage = UserDetailsPage->new($Request, "admin");
$UserDetailsPage->GeneratePage();
