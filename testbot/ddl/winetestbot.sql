CREATE DATABASE winetestbot DEFAULT CHARSET=utf8 DEFAULT COLLATE=utf8_bin;

USE winetestbot;

CREATE TABLE Users
(
  Name      VARCHAR(40)     NOT NULL,
  EMail     VARCHAR(40)     NOT NULL,
  Password  CHAR(49)        NOT NULL,
  Status    ENUM('active', 'disabled', 'deleted')  NOT NULL,
  RealName  VARCHAR(40)     NULL,
  ResetCode CHAR(32)        NULL,
  PRIMARY KEY(Name)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE Roles
(
  Name          VARCHAR(20)    NOT NULL,
  IsDefaultRole ENUM('Y', 'N') NOT NULL,
  PRIMARY KEY(Name)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE UserRoles
(
  UserName VARCHAR(40) NOT NULL,
  RoleName VARCHAR(20) NOT NULL,
  PRIMARY KEY (UserName, RoleName),
  FOREIGN KEY (UserName) REFERENCES Users(Name),
  FOREIGN KEY (RoleName) REFERENCES Roles(Name)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE Sessions
(
  Id        CHAR(32)        NOT NULL,
  UserName  VARCHAR(40)     NOT NULL,
  Permanent ENUM('Y', 'N')  NOT NULL,
  PRIMARY KEY (Id),
  FOREIGN KEY (UserName) REFERENCES Users(Name)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE VMs
(
  Name         VARCHAR(20)      NOT NULL,
  SortOrder    INT(3)           NOT NULL,
  Type         ENUM('win32', 'win64', 'build') NOT NULL,
  Role         ENUM('extra', 'base', 'winetest', 'retired', 'deleted') NOT NULL,
  Status       ENUM('dirty', 'reverting', 'sleeping', 'idle', 'running', 'off', 'offline', 'maintenance') NOT NULL,
  ChildPid     INT(5)           NULL,
  VirtURI      VARCHAR(64)      NOT NULL,
  VirtDomain   VARCHAR(32)      NOT NULL,
  IdleSnapshot VARCHAR(32)      NOT NULL,
  Hostname     VARCHAR(64)      NOT NULL,
  Description  VARCHAR(40)      NULL,
  Details      VARCHAR(512)     NULL,
  PRIMARY KEY (Name)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE Patches
(
  Id          INT(7)          NOT NULL AUTO_INCREMENT,
  WebPatchId  INT(7)          NULL,
  Received    DATETIME        NOT NULL,
  Disposition VARCHAR(40)     NOT NULL,
  AffectsTests ENUM('Y', 'N') NOT NULL,
  FromName    VARCHAR(40)     NULL,
  FromEMail   VARCHAR(40)     NULL,
  Subject     VARCHAR(120)    NULL,
  MessageId   VARCHAR(256)    NULL,
  PRIMARY KEY (Id),
  INDEX PatchesWebPatchId (WebPatchId)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE PendingPatchSets
(
  EMail      VARCHAR(40) NOT NULL,
  TotalParts INT(2)      NOT NULL,
  PRIMARY KEY (EMail, TotalParts)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE PendingPatches
(
  PendingPatchSetEMail      VARCHAR(40) NOT NULL,
  PendingPatchSetTotalParts INT(2)      NOT NULL,
  No                        INT(2)      NOT NULL,
  PatchId                   INT(7)      NOT NULL,
  FOREIGN KEY (PendingPatchSetEMail, PendingPatchSetTotalParts)
          REFERENCES PendingPatchSets(EMail, TotalParts),
  FOREIGN KEY (PatchId) REFERENCES Patches(Id),
  PRIMARY KEY (PendingPatchSetEMail, PendingPatchSetTotalParts, No)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE Branches
(
  Name      VARCHAR(20)     NOT NULL,
  IsDefault ENUM('Y', 'N')  NOT NULL,
  PRIMARY KEY(Name)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE Jobs
(
  Id         INT(5)      NOT NULL AUTO_INCREMENT,
  Archived   ENUM('Y', 'N') NOT NULL,
  BranchName VARCHAR(20) NOT NULL,
  UserName   VARCHAR(40) NOT NULL,
  Priority   INT(1)      NOT NULL,
  Status     ENUM('queued', 'running', 'completed', 'badpatch', 'badbuild', 'boterror', 'canceled') NOT NULL,
  Remarks    VARCHAR(128) NULL,
  Submitted  DATETIME    NULL,
  Ended      DATETIME    NULL,
  PatchId    INT(7)      NULL,
  FOREIGN KEY (BranchName) REFERENCES Branches(Name),
  FOREIGN KEY (UserName) REFERENCES Users(Name),
  FOREIGN KEY (PatchId) REFERENCES Patches(Id),
  PRIMARY KEY (Id),
  INDEX JobsArchived (Archived)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE Steps
(
  JobId                 INT(5) NOT NULL,
  No                    INT(2) NOT NULL,
  Type                  ENUM('suite', 'single', 'build', 'reconfig') NOT NULL,
  Status                ENUM('queued', 'running', 'completed', 'badpatch', 'badbuild', 'boterror', 'canceled', 'skipped') NOT NULL,
  FileName              VARCHAR(100) NOT NULL,
  FileType              ENUM('exe32', 'exe64', 'patchdlls', 'patchprograms') NOT NULL,
  InStaging             ENUM('Y', 'N') NOT NULL,
  DebugLevel            INT(2) NOT NULL,
  ReportSuccessfulTests ENUM('Y', 'N') NOT NULL,
  PRIMARY KEY (JobId, No),
  FOREIGN KEY (JobId) REFERENCES Jobs(Id)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE Tasks
(
  JobId        INT(5) NOT NULL,
  StepNo       INT(2) NOT NULL,
  No           INT(2) NOT NULL,
  Status       ENUM('queued', 'running', 'completed', 'badpatch', 'badbuild', 'boterror', 'canceled', 'skipped') NOT NULL,
  VMName       VARCHAR(20) NOT NULL,
  Timeout      INT(4) NOT NULL,
  CmdLineArg   VARCHAR(256) NULL,
  Started      DATETIME NULL,
  Ended        DATETIME NULL,
  TestFailures INT(6) NULL,
  PRIMARY KEY (JobId, StepNo, No),
  FOREIGN KEY(VMName) REFERENCES VMs(Name)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE RecordGroups
(
  Id           INT(6) NOT NULL AUTO_INCREMENT,
  Timestamp    DATETIME NOT NULL,
  PRIMARY KEY (Id)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE Records
(
  RecordGroupId INT(6) NOT NULL,
  Type         ENUM('engine', 'tasks', 'vmresult', 'vmstatus') NOT NULL,
  Name         VARCHAR(96) NOT NULL,
  Value        VARCHAR(64) NULL,
  PRIMARY KEY (RecordGroupId, Type, Name),
  FOREIGN KEY (RecordGroupId) REFERENCES RecordGroups(Id)
)
ENGINE=InnoDB DEFAULT CHARSET=utf8;

INSERT INTO Roles (Name, IsDefaultRole) VALUES('admin', 'N');
INSERT INTO Roles (Name, IsDefaultRole) VALUES('wine-devel', 'Y');

INSERT INTO Users (Name, EMail, Password, Status, RealName)
       VALUES('batch', '/dev/null', '*', 'disabled', 'Batch user for internal jobs');

INSERT INTO Branches (Name, IsDefault) VALUES('master', 'Y');

# Remember to change the winetestbot user password!
# (see doc/INSTALL.txt)
CREATE USER 'winetestbot'@'localhost' IDENTIFIED BY 'changeme!';

# Note that this user does not need any data definition grants.
GRANT SELECT on winetestbot.* TO 'winetestbot';
GRANT INSERT on winetestbot.* TO 'winetestbot';
GRANT UPDATE on winetestbot.* TO 'winetestbot';
GRANT DELETE on winetestbot.* TO 'winetestbot';
