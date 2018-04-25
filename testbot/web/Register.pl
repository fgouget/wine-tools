# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Register account page
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

package RegisterPage;

use ObjectModel::CGI::ItemPage;
our @ISA = qw(ObjectModel::CGI::ItemPage);

use URI::Escape;

use ObjectModel::BasicPropertyDescriptor;
use WineTestBot::Config;
use WineTestBot::Users;
use WineTestBot::Utils;


sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  $self->SUPER::_initialize($Request, $RequiredRole, CreateUsers());
  $self->{ExtraProperties} = [];
  if ($RegistrationQ)
  {
    $self->GetParam("RegA", "") if (!defined $self->GetParam("RegA"));
    push @{$self->{ExtraProperties}}, CreateBasicPropertyDescriptor("RegA", "Please demonstrate you are not a bot by answering this question: $RegistrationQ", !1, 1, "A", 40);
  }

  $self->GetParam("Remarks", "") if (!defined $self->GetParam("Remarks"));
  push @{$self->{ExtraProperties}}, CreateBasicPropertyDescriptor("Remarks", "Remarks", !1, !1, "textarea", 160);
}

sub GetTitle($)
{
  #my ($self) = @_;
  return "Request new account";
}

sub GetHeaderText($)
{
  #my ($self) = @_;
  return "Since an account will allow you to run code on this system, your " .
         "request for an account will have to be manually approved. That " .
         "should be no problem if you're a well-known member of the Wine " .
         "community. Otherwise please explain in a few words why you need an " .
         "account in the Remarks field.<br>\n" .
         "When your request has been approved, you'll receive a link via " .
         "email to activate your account and choose a password. Usually, " .
         "you should receive that email within a couple of hours.";
}

sub GetFooterText($)
{
  #my ($self) = @_;
  return "Your real name and email address will be treated confidentially " .
         "and will not be shown on any bot-accessible part of this site.";
}

sub DisplayProperty($$)
{
  my ($self, $PropertyDescriptor) = @_;

  my $PropertyName = $PropertyDescriptor->GetName();

  my $Display;
  if ($PropertyName ne "Name" && $PropertyName ne "EMail" &&
      $PropertyName ne "RealName")
  {
    return "";
  }

  return $self->SUPER::DisplayProperty($PropertyDescriptor);
}

sub GenerateFields($)
{
  my ($self) = @_;

  print "<div><input type='hidden' name='Status' value='active'></div>\n";

  $self->SUPER::GenerateFields();
  map { $self->GenerateField($_, "rw") } @{$self->{ExtraProperties}};

  $self->GenerateRequiredLegend();
  $self->{HasRequired} = !1;
}

sub GenerateActions($)
{
  #my ($self) = @_;
  print <<EOF;
<div class='DetailActions'>
<input type='submit' name='Action' value='Send request' />
</div>
EOF
}

sub OnSendRequest($)
{
  my ($self) = @_;

  if ($RegistrationQ)
  {
    my $RegA = $self->GetParam("RegA");
    if ($RegA !~ /$RegistrationARE/)
    {
      $self->{ErrMessage} = "Wrong 'captcha' answer. Please try again.";
      $self->{ErrField} = "Captcha";
      return !1;
    }
  }
  if (! $self->Save())
  {
    return !1;
  }

  my $Msg = "Username: " . $self->GetParam("Name") . "\n" .
            "EMail: " . $self->GetParam("EMail") . "\n" .
            "Real name: " . $self->GetParam("RealName") . "\n";
  if ($self->GetParam("Remarks"))
  {
    $Msg .= "Remarks:\n" . $self->GetParam("Remarks") . "\n";
  }
  my $URL = ($UseSSL ? "https://" : "http://") . $WebHostName .
            "/admin/UserDetails.pl?Key=" . uri_escape($self->GetParam("Name"));
  $Msg .= "\nTo approve or deny the request, please go to " . $URL;

  open (SENDMAIL, "|/usr/sbin/sendmail -oi -t -odq");
  print SENDMAIL <<"EOF";
From: $RobotEMail
To: $AdminEMail
Subject: winetestbot account request

$Msg
EOF
  close(SENDMAIL);

  return 1;
}

sub OnAction($$)
{
  my ($self, $Action) = @_;

  if ($Action eq 'Send request')
  {
    return $self->OnSendRequest();
  }

  return $self->SUPER::OnAction($Action);
}

sub GenerateBody($)
{
  my ($self) = @_;

  if ($self->{ActionPerformed})
  {
    print <<EOF;
<h1>Request new account</h1>
<div class='Content'>
<p>Your request is now waiting to be approved. Expect to receive a link via
email to activate your account and choose a password. Usually, you should
receive that email within a couple of hours.</p>
</div>
EOF
    return;
  }

  $self->SUPER::GenerateBody();
}


package main;

my $Request = shift;

my $RegisterPage = RegisterPage->new($Request, "");
$RegisterPage->GeneratePage();
