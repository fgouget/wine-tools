# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# WineTestBot feedback page
#
# Copyright 2010 Ge van Geldorp
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

package FeedbackPage;

use ObjectModel::BasicPropertyDescriptor;
use ObjectModel::CGI::FreeFormPage;
use WineTestBot::Config;

@FeedbackPage::ISA = qw(ObjectModel::CGI::FreeFormPage);

sub _initialize($$$)
{
  my ($self, $Request, $RequiredRole) = @_;

  my @PropertyDescriptors = (
    CreateBasicPropertyDescriptor("Name", "Name", !1, !1, "A", 40),
    CreateBasicPropertyDescriptor("EMail", "Email", !1, !1, "A", 40),
    CreateBasicPropertyDescriptor("Remarks", "Remarks", !1, 1, "textarea", 1024),
  );

  $self->SUPER::_initialize($Request, $RequiredRole, \@PropertyDescriptors);

  my $Session = $self->GetCurrentSession();
  if (defined($Session))
  {
    # Provide default values
    my $User = $Session->User;
    $self->GetParam("Name", $User->RealName) if (!defined $self->GetParam("Name"));
    $self->GetParam("EMail", $User->EMail) if (!defined $self->GetParam("EMail"));
  }
}

sub GetTitle($)
{
  #my ($self) = @_;
  return "Provide feedback";
}

sub GetHeaderText($)
{
  #my ($self) = @_;
  return "Remarks on how to improve this service are highly appreciated! " .
         "If you wish to stay anonymous, you don't have to enter your name " .
         "or email address.";
}

sub GetActions($)
{
  my ($self) = @_;

  my $Actions = $self->SUPER::GetActions();
  push @$Actions, "Send";

  return $Actions;
}

sub OnSend($)
{
  my ($self) = @_;

  if (! $self->Validate)
  {
    return !1;
  }

  open (SENDMAIL, "|/usr/sbin/sendmail -oi -t -odq");
  print SENDMAIL <<"EOF";
From: $RobotEMail
To: $AdminEMail
Subject: winetestbot feedback

EOF
  print SENDMAIL "Name: ", $self->GetParam("Name"), "\n";
  print SENDMAIL "EMail: ", $self->GetParam("EMail"), "\n\n";
  print SENDMAIL "Remarks:\n", $self->GetParam("Remarks"), "\n";
  close(SENDMAIL);

  return 1;
}

sub OnAction($$)
{
  my ($self, $Action) = @_;

  if ($Action eq "Send")
  {
    return $self->OnSend();
  }

  return $self->SUPER::OnAction($Action);
}

sub GenerateBody($)
{
  my ($self) = @_;

  if ($self->{ActionPerformed})
  {
    print "<h1>Feedback sent</h1>\n";
    print "<div class='Content'>\n";
    print "<p>Thanks for taking the time to provide feedback.</p>\n";
    print "</div>";
    return;
  }

  $self->SUPER::GenerateBody();
}

package main;

my $Request = shift;

my $FeedbackPage = FeedbackPage->new($Request, "");
$FeedbackPage->GeneratePage();
