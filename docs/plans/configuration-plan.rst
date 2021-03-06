
Plans for Configuration
#######################

 - Provide an API for editing the config
 - Provide a Web interface for editing the config
 - Changes to the config should not require a restart.
 - The manager should provide a web interface to update it's config and the config of it's stations.
 - The manager's web interface should be able up perform conditional(e.g. :code:`room="B100"` or :code:`eventstreamr-command="no-op"`) mass-updates of any property or property set.
 - Each change should update the respective file in the :file:`.configs/` directory.

Manager
=======

 1. Load saved configuration(if it exists)(:file:`.configs/manager.json`)
 2. Load :file:`manager.json` if it has changed and use it's values to overwrite existing.

Station
=======

 1. Load saved configuration(if it exists)(:file:`.configs/station.json`)
 2. Load :file:`station.json` if it has changed and use it's values to overwrite existing.
 3. Once connected to a manager, merge the manager's station config into own. Own config takes precedence.


Configuration File Formats
==========================


Backup Configuration File(:file:`.configs/`)
--------------------------------------------

The :file:`.configs/station.json` has the following format::

    {
      "encode": {
        "manager": {
          "priority": -100,
          "config": {
            "localsave": "/tmp",
            "extensions": ["ogg", "ogv"]
          }
        },
        "station": {
          "priority": 100,
          "config": {
            "script": "scripts/run_encode.py"
          }
        }
      },
      "capture": {
        "manager": {
          "priority": -100,
          "config": {
            "localbackup": "~/backups"
            "record" {
              "boardcast"
            }
          }
        },
        "monitoring-station": {
          "priority": -50,
          "config": {
            "localbackup": "~/localbackups"
          }
        },
        "station": {
          "priority": 100,
          "config": {
            "record": {
              "device": "/dev/null",
            }
          }
        }
      }
    }

If identical keys are present in multiple configs then the config with the higher(larger numerically) priority will be used(by default) unless some custom merging scheme is defined in the service's configuration. Adding a new config source with the same priority as another source is invalid and has undefined consequences.
