# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# WineTestBot logout page
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

package LoginPage;

use ObjectModel::CGI::FreeFormPage;
our @ISA = qw(ObjectModel::CGI::FreeFormPage);

use ObjectModel::BasicPropertyDescriptor;
use WineTestBot::Config;
use WineTestBot::Users;
use WineTestBot::Utils;
use WineTestBot::CGI::Sessions;


sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->GetPageBase()->CheckSecurePage();

  my @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("Name", "Username", 1, 1, "A", 40),
    CreateBasicPropertyDescriptor("Password", "Password", !1, 1, "A", 32),
    CreateBasicPropertyDescriptor("AutoLogin", "Log me in automatically each visit", !1, !1, "B", 1),
  );

  $self->SUPER::_initialize($Request, $RequiredRole, \@PropertyDescriptors);
}

sub GetTitle($)
{
  #my ($self) = @_;
  return "Log in";
}

sub GetFooterText($)
{
  #my ($self) = @_;
  return defined($LDAPServer) ? "" :
         "<a href='ForgotPassword.pl'>I forgot my password</a><br>\n" .
         "<a href='Register.pl'>I want to register an account</a>";
}

sub GetInputType($$)
{
  my ($self, $PropertyDescriptor) = @_;

  if ($PropertyDescriptor->GetName() eq "Password")
  {
    return "password";
  }

  return $self->SUPER::GetInputType($PropertyDescriptor);
}

sub GenerateFields($)
{
  my ($self) = @_;

  if (defined($self->GetParam("Target")))
  {
    print "<div><input type='hidden' name='Target' value='",
          $self->escapeHTML($self->GetParam("Target")), "'></div>\n";
  }

  $self->SUPER::GenerateFields();
}

sub GetActions($)
{
  my ($self) = @_;

  my $Actions = $self->SUPER::GetActions();
  push @$Actions, "Log in";

  return $Actions;
}

sub OnLogIn($)
{
  my ($self) = @_;

  if (! $self->Validate)
  {
    return !1;
  }

  my $OldSession = $self->GetCurrentSession();

  my $Users = CreateUsers();
  my ($ErrMessage, $User) = $Users->Authenticate($self->GetParam("Name"),
                                                 $self->GetParam("Password"));
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

  my $Target = $self->GetParam("Target");
  if (! defined($Target) || $Target eq "" || substr($Target, 0, 1) ne "/")
  {
    $Target = "/index.pl";
  }
  $self->Redirect(MakeSecureURL($Target)); # does not return
  exit;
}

sub OnAction($$)
{
  my ($self, $Action) = @_;

  if ($Action eq "Log in")
  {
    return $self->OnLogIn();
  }

  return $self->SUPER::OnAction($Action);
}


package main;

my $Request = shift;

my $LoginPage = LoginPage->new($Request, "");
$LoginPage->GeneratePage();
