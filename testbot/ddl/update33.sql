USE winetestbot;

ALTER TABLE VMs
  ADD Errors INT(2) NULL
      AFTER Status;
