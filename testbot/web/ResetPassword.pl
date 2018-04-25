# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# WineTestBot password reset page
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

package ResetPasswordPage;

use ObjectModel::CGI::FreeFormPage;
our @ISA = qw(ObjectModel::CGI::FreeFormPage);

use ObjectModel::BasicPropertyDescriptor;
use WineTestBot::Users;
use WineTestBot::Utils;
use WineTestBot::CGI::Sessions;


sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->GetPageBase()->CheckSecurePage();

  my @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("Name", "Username", 1, 1, "A", 40),
    CreateBasicPropertyDescriptor("ResetCode", "Activation code", !1, 1, "A", 32),
    CreateBasicPropertyDescriptor("Password1", "Password", !1, 1, "A", 32),
    CreateBasicPropertyDescriptor("Password2", "Password (repeat)", !1, 1, "A", 32),
  );

  $self->SUPER::_initialize($Request, $RequiredRole, \@PropertyDescriptors);
}

sub GetTitle($)
{
  #my ($self) = @_;
  return "Reset password";
}

sub GetHeaderText($)
{
  #my ($self) = @_;
  return "If you don't have an account yet, you can " .
         "<a href='Register.pl'>register</a> for one.";
}

sub GetInputType($$)
{
  my ($self, $PropertyDescriptor) = @_;

  if (substr($PropertyDescriptor->GetName(), 0, 8) eq "Password")
  {
    return "password";
  }

  return $self->SUPER::GetInputType($PropertyDescriptor);
}

sub GetActions($)
{
  my ($self) = @_;

  my $Actions = $self->SUPER::GetActions();
  push @$Actions, "Change password";

  return $Actions;
}

sub Validate($)
{
  my ($self) = @_;

  if (! $self->SUPER::Validate())
  {
    return !1;
  }

  if ($self->GetParam("Password1") ne $self->GetParam("Password2"))
  {
    $self->{ErrField} = "Password1";
    $self->{ErrMessage} = "Passwords don't match";
    return !1;
  }

  return 1;
}

sub OnChangePassword($)
{
  my ($self) = @_;

  if (! $self->Validate)
  {
    return !1;
  }

  my $OldSession = $self->GetCurrentSession();

  my $Users = CreateUsers();
  my $User = $Users->GetItem($self->GetParam("Name"));
  if (! defined($User))
  {
    $self->{ErrField} = "Name";
    $self->{ErrMessage} = "Unknown username or incorrect activation code";
    return !1;
  }
  $self->{ErrMessage} = $User->ResetPassword($self->GetParam("ResetCode"),
                                             $self->GetParam("Password1"));
  if (defined($self->{ErrMessage}))
  {
    $self->{ErrField} = "Name";
    return !1;
  }

  my ($ErrMessage, $User) = $Users->Authenticate($self->GetParam("Name"),
                                                 $self->GetParam("Password1"));
  if ($ErrMessage)
  {
    $self->{ErrMessage} = $ErrMessage;
    $self->{ErrField} = "Name";
    return !1;
  }

  my $Sessions = CreateSessions();
  ($ErrMessage, my $Session) = $Sessions->NewSession($User,
                                                     defined($self->GetParam("AutoLogin")));
  if ($ErrMessage)
  {
    $self->{ErrMessage} = $ErrMessage;
    $self->{ErrField} = "Name";
    return !1;
  }

  if ($OldSession)
  {
    $Sessions->DeleteItem($OldSession);
  }

  $self->SetCurrentSession($Session);

  return 1;
}

sub OnAction($$)
{
  my ($self, $Action) = @_;

  if ($Action eq "Change password")
  {
    return $self->OnChangePassword();
  }

  return $self->SUPER::OnAction($Action);
}

sub GenerateBody($)
{
  my ($self) = @_;

  if ($self->{ActionPerformed})
  {
    print "<h1>Reset password</h1>\n";
    print "<div class='Content'>\n";
    print "<p>Your password was successfully changed.</p>\n";
    print "</div>\n";
    return;
  }

  $self->SUPER::GenerateBody();
}


package main;

my $Request = shift;

my $ResetPasswordPage = ResetPasswordPage->new($Request, "");
$ResetPasswordPage->GeneratePage();
