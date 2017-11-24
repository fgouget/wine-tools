# -*- Mode: Perl; perl-indent-level: 2; indent-tabs-mode: nil -*-
# WineTestBot configuration
#
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

# Set to "1" if you have a valid SSL certificate, set to "!1" if you don't
$WineTestBot::Config::UseSSL = 1;

# The DBI data source name of the database (e.g. "DBI:mysql:winetestbot")
$WineTestBot::Config::DbDataSource = "DBI:mysql:winetestbot";

# The name of the database account
$WineTestBot::Config::DbUsername = "winetestbot";

# The password of the database account
$WineTestBot::Config::DbPassword = "";

# Name and email address of the WineTestBot administrator
$WineTestBot::Config::AdminEMail = undef;

# Name and address for the 'From' field of mails sent by WineTestBot
$WineTestBot::Config::RobotEMail = undef;

# If set, sends the results to the specified email address instead of the
# patch author. Set it to undef once your WineTestBot installation works and
# can provide useful results to Wine developers.
$WineTestBot::Config::WinePatchToOverride = $WineTestBot::Config::AdminEMail;

# If set, CC the results to the specified name + email address, for instance
# the wine-devel mailing list.
$WineTestBot::Config::WinePatchCc = "";

# Host name of the web interface
$WineTestBot::Config::WebHostName = undef;

# The question to ask to filter out bots trying to register, and the regular
# expression that the answer must match.
$RegistrationQ = "What is the software project being tested?";
$RegistrationARE = "(?i:wine)";

# Prefix of the tag used for sending winetest reports
$WineTestBot::Config::TagPrefix = undef;

# If you want to use LDAP authentication instead of built-in, you'll have
# to define all 6 LDAP settings: $LDAPServer, $LDAPBindDN, $LDAPSearchBase,
# $LDAPSearchFilter, $LDAPRealNameAttribute and $LDAPEMail
# LDAP server, can be in URL format like "ldaps://ldap.example.com"
$WineTestBot::Config::LDAPServer = undef;

# DN used to bind to LDAP, %USERNAME% is replaced by the login name provided
# by the user. E.g. "%USERNAME%\@example.com" (remember to escape the @)
$WineTestBot::Config::LDAPBindDN = undef;

# DN used as search base to obtain user information, e.g.
# "CN=Users,DC=example,DC=com"
$WineTestBot::Config::LDAPSearchBase = undef;

# Filter expression, %USERNAME% is replaced by login name, e.g.
# "(sAMAccountName=%USERNAME%)"
$WineTestBot::Config::LDAPSearchFilter = undef;

# LDAP attribute for a users real name
$WineTestBot::Config::LDAPRealNameAttribute = undef;

# LDAP attribute for a users email address
$WineTestBot::Config::LDAPEMailAttribute = undef;

# The port the VM agents are listening on
$WineTestBot::Config::AgentPort = undef;

# This specifies if and how to do SSH tunneling.
# - If unset then tunneling is automatic based on the VM's VirtURI setting.
# - If set to an SSH URI, then tunneling is performed using these parameters.
# - Any other setting disables SSH tunneling. In particular to disable
#   tunneling for SSH VirtURIs it is recommended to set this to 'never'.
$WineTestBot::Config::Tunnel = undef;

# If set this specifies the SSH tunnel parameters to be used for the
# TestAgent connection. This is mostly useful for parameters that cannot be
# specified through the SSH URI, like the key filenames. Listed below are
# the supported settings. For a full reference, see the Net::SSH2::auth()
# documentation. Note though that interactive methods are disabled.
# - username
# - password
# - publickey
# - privatekey
# - hostname
# - local_username
$WineTestBot::Config::TunnelDefaults = undef;


1;
