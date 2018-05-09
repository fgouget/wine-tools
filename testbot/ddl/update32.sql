USE winetestbot;

ALTER TABLE VMs
  ADD ChildDeadline DATETIME NULL
      AFTER ChildPid;
