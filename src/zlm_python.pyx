##
## This is main Zabbix Loadable Module code
## Author: Vladimir Ulogov
##         vladimir.ulogov@zabbix.com
##

import sys,os
from multiprocessing.forking import Popen
from multiprocessing.process import Process
from multiprocessing.managers import SyncManager,Server

##
## Logging
##

##
## Declaration of the Zabbix core logging functions
##

cdef extern void __zbx_zabbix_log(int level, const char *fmt, ...)

##
## Wrapper functions for the Zabbix core logging. WIll be exported as Python functions
##

def log_critical(msg):
    __zbx_zabbix_log(1, msg)
def log_error(msg):
    __zbx_zabbix_log(2, msg)
def log_warning(msg):
    __zbx_zabbix_log(3, msg)
def log_debug(msg):
    __zbx_zabbix_log(4, msg)
def log_trace(msg):
    __zbx_zabbix_log(5, msg)

##
## Process management
##

##
## Declaration of the Zabbix core process management functions
##
cdef extern int	zbx_child_fork()
cdef extern void setproctitle_set_status(char * status)

##
## Wrapper functions for the Zabbix core process management functions. Will be exported as Python functions.
##
def ZBX_proc_fork():
    return zbx_child_fork()

def ZBX_proc_settitle(char * title):
    setproctitle_set_status(title)

##
## Subclassing of some multiprocessing classes to make them "play nice" with the Zabbix
##
class ZBX_Popen(Popen):
        def __init__(self, process_obj):
            sys.stdout.flush()
            sys.stderr.flush()
            self.returncode = None

            self.pid = ZBX_proc_fork()
            if self.pid == 0:
                if 'random' in sys.modules:
                    import random
                    random.seed()
                code = process_obj._bootstrap()
                sys.stdout.flush()
                sys.stderr.flush()
                os._exit(code)

class ZBX_Process(Process):
    _Popen = ZBX_Popen
    def title(self, title):
        ZBX_proc_settitle(title)

class ZBX_mp_Server(Server):
    def serve_forever(self):
        setproctitle_set_status("zlm-python context manager is running...")
        log_warning("ZLM-python(CM): Context Manager is entering the loop.")
        Server.serve_forever(self)
class ZBX_mp_Manager(SyncManager):
    _Server =  ZBX_mp_Server

##
## ZLM-python in-memory RRD designed to work with Global context
##

class ZLM_RRD:
    ##
    ## ZLM_RRD constructor
    ## Parameter:
    ##      ns  - reference to a Global NameSpace
    ##
    def __init__(self, ns):
        self.isReady = False
        self.ns = ns
        try:
            self.maxsize = int(self.ns.config["rrd"]["maxsize"])
        except:
            self.maxsize = None
            log_warning("ZLM-python(RRD): Can not read maximum size of RRD database")
        self.update()
    ##
    ## .update()    - sync data from manager to the current thread
    ##
    def update(self):
        if not self.maxsize:
            return
        try:
            self.rrd = self.ns.rrd
        except:
            self.rrd = {}
            self.ns.rrd = self.rrd
            log_warning("ZLM-python(RRD): Creating the empty RRD database")
        self.isReady = True
    ##
    ## .set()   - set value in RRD database
    ##  Parameters:
    ##      collection      - RRD collection
    ##      item            - Name of the item in the collection
    ##      value           - value to be added to the tail of RRD
    ##
    def set(self, collection, item, value):
        import time
        self.update()
        if not self.rrd.has_key(collection):
            self.rrd[collection] = {}
        if not self.rrd[collection].has_key(item):
            self.rrd[collection][item] = [value,]
        else:
            if len(self.rrd[collection][item]) >= self.maxsize:
                del self.rrd[collection][item][0]
            self.rrd[collection][item].append((time.time(), item))
        self.ns.rrd = self.rrd
    ##
    ## .get()   - get the data from RRD
    ##  Parameters
    ##      collection      - RRD collection
    ##      item            - Name of the item in the collection
    ##      age             - return the values within specific age in seconds
    ##  Returns:
    ##      array of tuples (stamp, value)
    ##
    def get(self, section, item, age=None):
        import time
        self.update()
        if not self.rrd.has_key(section):
            return None
        if not self.rrd.has_key[section].has_key(item):
            return None
        if not age:
            return self.rrd[section][item]
        else:
            ret = []
            stamp = time.time()
            for s,v in self.rrd[section][item]:
                if stamp-s < age:
                    ret.append((s,v))
            return ret
    ##
    ## .clear()   - clear the item and it's data  from RRD
    ##  Parameters
    ##      collection      - RRD collection
    ##      item            - Name of the item in the collection
    ##  Returns:
    ##      True or False
    ##
    def clear(self, section, item):
        self.update()
        try:
            del self.rrd[section][item]
            self.ns.rrd = self.rrd
            return True
        except:
            return False

##
## ZLM-python background metric collector
##

class ZLM_Metric_Collector(ZBX_Process):
    _name = "generic_collector"
    def collect(self):
        pass
    def run(self):
        import time
        self.ns = self._kwargs["ns"]
        try:
            self.wait = float(self.ns.config[self._name]["wait"])
        except:
            self.wait = 1.0
        try:
            self._title = self.ns.config[self._name]["collector_name"]
        except:
            self._title = "Default collector"
        stamp = time.time()
        while True:
            self.collect()
            time.sleep(self.wait)
##
## ZLM-python: reading config file and returns a dictionary
##

class ZLM_INI:
    def __init__(self, cfg_path, default_config_filename="zlm_python.ini"):
        from ConfigParser import SafeConfigParser
        self.path = "%s/%s"%(cfg_path, default_config_filename)
        self.cfg  = SafeConfigParser()
        self.isReady = False
        if len(self.cfg.read(self.path)) != 0:
            self.isReady = True
            log_warning("ZLM-python(Config): Configuration file %s found."%self.path)
        else:
            log_warning("ZLM-python(Config): Configuration file %s not found."%self.path)
    ##
    ## Return module configuration file as dictionary
    ##
    def Config(self):
        ret = {}
        for s in self.cfg.sections():
            ret[s] = {}
            for i,v in self.cfg.items(s):
                ret[s.lower()][i.lower()] = v
                log_warning("ZLM-python(Config): %s[%s]=%s"%(s,i,v))
        return ret
##
## Callbacks for the Zabbix loadable module interface
##


##
## This function is executed during the module startup
## Parameters:
##              cfg_path - Path of where zlm_python.so and it's configuration is located
## Returns:
##              dictionary with following keys:
##                      "m"    - multiprocessing manager
##                      "ns"   - Global shared "namespace" context
##

cdef public object ZBX_startup (char * cfg_path):
    log_warning("ZLM-python(Startup) Initializning")
    manager = ZBX_mp_Manager()
    manager.start()
    cfg = ZLM_INI(cfg_path)
    config = cfg.Config()
    ret = {"m":manager, "ns":manager.Namespace(), "ns_lock":manager.Lock()}
    ret["ns"].config = config
    return ret
##
## This function is executed during py[...] call
## Parameters:
##              ctx     - dictionary returned by ZBX_startup
##              params  - parameters passed from Zabbix metric collection call
## Returns:
##          Python object which could be:
##              data    - ether float, or long or string. Will be passed to a Zabbix
##              Tuple (retcode, data, traceback):
##                  if retcode == 0, ZLM-python will pass "data" as a message and will return SYS_RET_FAIL
##                  if retcode != 0, ZLM-python will pass "data" as a data
##

cdef public object ZBX_call (object ctx, object params):
    import posixpath
    import traceback
    import imp
    import zlm_python as zlm

    #log_warning("%s  %s"%(str(ctx), str(params)))
    if len(params) < 1:
        return (0,"You did not pass the function name", "")
    cmd = params[0]
    f_params = (ctx["ns"],) + tuple(list(params)[1:])
    p_cmd = cmd.split(".")
    name = p_cmd[0]
    try:
        method = p_cmd[1]
    except:
        method = "main"
    try:
        c_params = tuple(p_cmd[2:])
    except:
        c_params = ()
    if sys.modules.has_key(name):
        mod = sys.modules[name]
        log_warning("ZLM-python(Call): picking up module %s from the cache"%name)
    else:
        try:
            fp, pathname, description = imp.find_module(name)
            if posixpath.dirname(pathname).split("/")[-1] != "pymodules":
                ## If discovered module isn't in pymodules, we don't want to call it
                raise ImportError, name
        except:
            log_warning("ZLM-python(Call): Module %s do not exists"%name)
            return (0,"ZLM-python: Module %s do not exists"%name,traceback.format_exc())
        try:
            mod = imp.load_module(name, fp, pathname, description)
        except:
            log_warning("ZLM-python(Call): Module %s can not be loaded"%name)
            _tbstr = traceback.format_exc()
            return (0,"ZLM-python: Module %s can not be loaded: %s"%(name,_tbstr), _tbstr)
        finally:
            fp.close()
        log_warning("ZLM-python(Call): Module %s->%s has been loaded from %s"%(name, method, pathname))
    try:
        ret = apply(getattr(mod, method), f_params+c_params)
    except:
        log_warning("ZLM-python(Call): Module %s->%s threw traceback"%(name, method))
        _tbstr = traceback.format_exc()
        return (0,"ZLM-python: Module %s->%s threw traceback: %s"%(name, method, _tbstr),_tbstr)
    sys.modules[name] = mod
    return (1, ret, None)


##
## This function will be called during module de-initialization, which is usually happens during shutdown
## Parameters:
##      ctx     - dictionary returned by ZBX_startup
## Returns:
##      None
##
##

cdef public ZBX_finish(object ctx):
    log_warning("ZLM-python(Shutdown): Doing so.")
    ctx["m"].shutdown()
    log_warning("ZLM-python(Shutdown): CM manager is down.")
    del ctx