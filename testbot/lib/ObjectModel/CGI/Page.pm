# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# Base class for web pages
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

package ObjectModel::CGI::Page;

=head1 NAME

ObjectModel::CGI::Page - Base class for web pages

=cut

use CGI;

use vars qw(@ISA @EXPORT $PageBaseCreator);

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(new SetPageBaseCreator);

sub new($$$@)
{
  my $class = shift;
  my ($Request, $_RequiredRole) = @_;

  my $self = {Request => $Request,
              CGIObj => CGI->new($Request),
              ErrMessage => undef,
              ErrField => undef};
  $self = bless $self, $class;
  $self->{PageBase} = &$PageBaseCreator($self, @_);
  $self->_initialize(@_);
  return $self;
}

sub _initialize($$$)
{
  #my ($self, $Request, $RequiredRole) = @_;
}

=pod
=over 12

=head1 C<GetParamNames()>

Returns the list of parameter names.

=back
=cut

sub GetParamNames($)
{
  my $self = shift;

  return $self->{CGIObj}->param();
}

=pod
=over 12

=head1 C<GetParam()>

This thunks to CGI::param() and thus takes the same arguments list but forces
the result to scalar context to avoid security issues.
To get the list of parameter names use GetParamNames().

=back
=cut

sub GetParam($@)
{
  my $self = shift;

  return scalar($self->{CGIObj}->param(@_));
}

sub CGI($)
{
  my ($self) = @_;

  return $self->{CGIObj};
}

sub escapeHTML($$)
{
  my ($self, $String) = @_;

  return $self->{CGIObj}->escapeHTML($String);
}

sub GetPageBase($)
{
  my ($self) = @_;

  return $self->{PageBase};
}

sub GenerateHttpHeaders($)
{
  my ($self) = @_;

  $self->{PageBase}->GenerateHttpHeaders($self);
}

sub UnsetCookies($)
{
  my ($self) = @_;

  $self->{PageBase}->UnsetCookies($self);
}

sub SetCookies($)
{
  my ($self) = @_;

  $self->{PageBase}->SetCookies($self);
}

=pod
=over 12

=head1 C<GetPageTitle()>

This returns the page title as put in the HTML header.
Note that this may not be valid HTML and thus need escaping.

=back
=cut

sub GetPageTitle($)
{
  my ($self) = @_;

  return $self->{PageBase}->GetPageTitle($self);
}

=pod
=over 12

=head1 C<GetTitle()>

This returns the title for the current web page or email section.
Note that this may not be valid HTML and thus need escaping.

=back
=cut

sub GetTitle($)
{
  #my ($self) = @_;
  return undef;
}

sub GenerateHeader($)
{
  my ($self) = @_;

  $self->{PageBase}->GenerateHeader($self);
}

sub GenerateFooter($)
{
  my ($self) = @_;

  $self->{PageBase}->GenerateFooter($self);
}

sub GenerateErrorDiv($)
{
  my ($self) = @_;

  $self->{PageBase}->GenerateErrorDiv($self);
}

sub GenerateErrorPopup($)
{
  my ($self) = @_;

  $self->{PageBase}->GenerateErrorPopup($self);
}

sub GenerateBody($)
{
  my ($self) = @_;

  die "Pure virtual function " . ref($self) . "::GenerateBody called";
}

sub GeneratePage($)
{
  my ($self) = @_;

  $self->GenerateHttpHeaders();
  $self->GenerateHeader();
  $self->GenerateBody();
  $self->GenerateFooter();
}

sub Redirect($$)
{
  my ($self, $Location) = @_;

  $self->{PageBase}->Redirect($self, $Location);
}

sub GetCurrentSession($)
{
  my ($self) = @_;

  return $self->{PageBase}->GetCurrentSession();
}

sub SetCurrentSession($$)
{
  my ($self, $Session) = @_;

  $self->{PageBase}->SetCurrentSession($self, $Session);
}

sub GetErrMessage($)
{
  my ($self) = @_;

  return $self->{ErrMessage};
}

sub GetErrField($)
{
  my ($self) = @_;

  return $self->{ErrField};
}

sub SetPageBaseCreator($)
{
  ($PageBaseCreator) = @_;
}

1;
