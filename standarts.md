# Architecture

- services call storage
- storage never called by a screen directly, indirectly only via services
- files are classified by feature, not by type
- each feature has its own folder with all necessary files inside (screens, services, storage)

# Code style
- comments and variables in english
- do not skip lines in code, takes place.