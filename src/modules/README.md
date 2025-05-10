Each subdirectory defines everything for installing and upgrading a given module
anything configuration needed is done from data in the configuration directory
each directory have an "install.sh" that will install the module.
the overall CI/CD pipeline will only install and update the modules that are configured as active inthe configuration directory
