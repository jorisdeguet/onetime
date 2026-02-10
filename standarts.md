# Architecture

- services call storage
- storage never called by a screen directly, indirectly only via services
- we do not skip lines in the code, only between functions
- files are classified type 
  - there is a package for l10n
  - one for services
  - one for screens
  - one for models that are going to be stored locally
  - one for models that are going to be stored in the firestore
  - one for generated code
  - one for config files
- 

# Code style
- comments and variables in english
- do not skip lines in code, takes place.