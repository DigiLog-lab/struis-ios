/* Included after pinned functionParameters; preserves the known command resolver. */
extern void resetEnvironment(pid_t pid);
extern void storeEnvironment(char *envp[]);
extern char **environmentVariables(pid_t pid);
extern char **environ;
static void StruisScopedEnvironmentDestroy(char **snapshot) {
    if(!snapshot) return;
    for(size_t i=0;snapshot[i];i++) free(snapshot[i]);
    free(snapshot);
}
static char **StruisScopedEnvironmentCopy(char **source) {
    if(!source) return NULL;
    size_t count=0;
    while(source[count]) count++;
    char **snapshot=calloc(count+1,sizeof(char *));
    if(!snapshot) return NULL;
    for(size_t i=0;i<count;i++) {
        snapshot[i]=strdup(source[i]);
        if(!snapshot[i]) { StruisScopedEnvironmentDestroy(snapshot); return NULL; }
    }
    return snapshot;
}
static sessionParameters *StruisScopedSessionCopy(sessionParameters *source) {
    sessionParameters *copy=malloc(sizeof(*copy));
    if(!copy) return NULL;
    *copy=*source;
    copy->commandName=calloc(source->numCommandsAllocated,sizeof(char *));
    if(!copy->commandName) { free(copy); return NULL; }
    for(int i=0;i<source->numCommandsAllocated;i++) {
        copy->commandName[i]=calloc(NAME_MAX,1);
        if(!copy->commandName[i]) {
            for(int j=0;j<i;j++) free(copy->commandName[j]);
            free(copy->commandName); free(copy); return NULL;
        }
        if(i<source->numCommand) memcpy(copy->commandName[i],source->commandName[i],NAME_MAX);
    }
    copy->global_errno=127;
    copy->current_command_root_thread=0; copy->lastThreadId=0; copy->mainThreadId=0;
    copy->isMainThread=false;
    return copy;
}
static void StruisScopedSessionDestroy(sessionParameters *session) {
    for(int i=0;i<session->numCommandsAllocated;i++) free(session->commandName[i]);
    free(session->commandName); free(session);
}
static void StruisScopedCleanup(void *parameters) {
    functionParameters *p=parameters;
    /* The stage owns its three borrowed FILEs until all sequential AST work ends.
       Only the explicit redirect/pipe transfer owned by this command is closed. */
    if(p->stdout) fflush(p->stdout);
    if(p->stderr && p->stderr!=p->stdout) fflush(p->stderr);
    FILE *streams[3]={p->stdin,p->stdout,p->stderr};
    bool owned[3]={p->scopedOwnIn,p->scopedOwnOut,p->scopedOwnErr};
    for(int i=0;i<3;i++) if(owned[i] && streams[i]) {
        bool prior=false; for(int j=0;j<i;j++) if(owned[j] && streams[j]==streams[i]) prior=true;
        if(!prior) fclose(streams[i]);
    }
    const char *command=p->argv_ref?p->argv_ref[0]:p->argv[0];
    if(strncmp(command,"python",6)==0) PythonIsRunning[p->numInterpreter]=false;
    else if(strncmp(command,"perl",4)==0) PerlIsRunning[p->numInterpreter]=false;
    else if(strcmp(command,"dash")==0) dashIsRunning[p->numInterpreter]=false;
    else if(strcmp(command,"ssh")==0) sshIsRunning[p->numInterpreter]=false;
    else if(strcmp(command,"curl")==0) curlIsRunning=false;
    else if(strcmp(command,"scp")==0 || strcmp(command,"sftp")==0) scpIsRunning=false;
    else if(strcmp(command,"rsync")==0 || strcmp(command,"openrsync")==0) rsyncIsRunning[p->numInterpreter]=false;
    else if([TeXcommands containsObject:[NSString stringWithUTF8String:command]]) TeXIsRunning[p->numInterpreter]=false;
    for(int i=0;i<p->argc;i++) free(p->argv_ref?p->argv_ref[i]:p->argv[i]);
    free(p->argv_ref); free(p->argv);
    if((p->dlHandle!=RTLD_SELF)&&(p->dlHandle!=RTLD_MAIN_ONLY)&&(p->dlHandle!=RTLD_DEFAULT)&&(p->dlHandle!=RTLD_NEXT)) dlclose(p->dlHandle);
    StruisScopedSessionDestroy(p->session);
    free(p);
    thread_stdin=thread_stdout=thread_stderr=NULL; thread_context=NULL; currentSession=NULL;
    /* Publish completion only after streams and session are no longer referenced. */
    resetEnvironment(ios_currentPid());
    StruisCommandScopeFinish();
}
/* Same per-command parser reset as the pinned run_function. The pinned getopt
   resets its scan state only when this thread's __db_getopt_reset is set. */
static void StruisScopedResetParser(void) {
    optind=1; opterr=1; optreset=1; __db_getopt_reset=1;
}
static void *StruisScopedRun(void *parameters) {
    functionParameters *p=parameters;
    int oldCancel; pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,&oldCancel);
    if(StruisCommandScopeAdopt(p->scopedPid)) return NULL; /* captured one-shot trusted launch */
    StruisScopedResetParser();
    currentSession=p->session;
    thread_stdin=p->stdin; thread_stdout=p->stdout; thread_stderr=p->stderr; thread_context=p->context;
    p->argv_ref=malloc(sizeof(char*)*(p->argc+1));
    if(p->argv_ref) for(int i=0;i<p->argc;i++) p->argv_ref[i]=p->argv[i];
    pthread_cleanup_push(StruisScopedCleanup,p);
    pthread_setcancelstate(oldCancel,NULL);
    @try {
        if(!p->argv_ref) StruisCommandScopeResult(ENOMEM);
        else StruisCommandScopeResult(p->function(p->argc,p->argv));
    } @catch(NSException *exception) {
        (void)exception; StruisCommandScopeResult(1);
    }
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,NULL);
    pthread_cleanup_pop(1);
    return NULL;
}
static void StruisScopedDiscard(functionParameters *p) {
    FILE *streams[3]={p->stdin,p->stdout,p->stderr}; bool owned[3]={p->scopedOwnIn,p->scopedOwnOut,p->scopedOwnErr};
    for(int i=0;i<3;i++) if(owned[i] && streams[i]) { bool prior=false; for(int j=0;j<i;j++) if(owned[j] && streams[j]==streams[i]) prior=true; if(!prior) fclose(streams[i]); }
    for(int i=0;i<p->argc;i++) free(p->argv[i]); free(p->argv);
    if((p->dlHandle!=RTLD_SELF)&&(p->dlHandle!=RTLD_MAIN_ONLY)&&(p->dlHandle!=RTLD_DEFAULT)&&(p->dlHandle!=RTLD_NEXT)) dlclose(p->dlHandle);
    if(p->session) StruisScopedSessionDestroy(p->session);
    free(p);
}
static void StruisScopedPopCreatorCommand(void) {
    if(currentSession->numCommand>0) currentSession->numCommand--;
    if(currentSession->numCommand==0) currentSession->commandName[0][0]=0;
}
static int StruisScopedLaunch(functionParameters *p) {
    int oldCancel; pthread_setcancelstate(PTHREAD_CANCEL_DISABLE,&oldCancel);
    /* actual trusted pointer identities; no standard descriptor-number guesses */
    p->scopedOwnIn=p->isPipeIn && p->stdin!=currentSession->stdin && p->stdin!=currentSession->stdout && p->stdin!=currentSession->stderr;
    p->scopedOwnOut=p->isPipeOut && p->stdout!=currentSession->stdin && p->stdout!=currentSession->stdout && p->stdout!=currentSession->stderr;
    p->scopedOwnErr=p->isPipeErr && p->stderr!=currentSession->stdin && p->stderr!=currentSession->stdout && p->stderr!=currentSession->stderr;
    p->session=NULL;
    int error=StruisCommandScopeCapture(&p->scopedPid);
    if(error==EINVAL) {
        pid_t implicit=ios_fork();
        error=implicit<0?errno:StruisCommandScopeCapture(&p->scopedPid);
    }
    if(error) {
        StruisScopedPopCreatorCommand(); StruisScopedDiscard(p);
        pthread_setcancelstate(oldCancel,NULL); return error;
    }
    p->session=StruisScopedSessionCopy(currentSession);
    /* Resolver pushed this command on the creator's stack. Only the snapshot
       keeps that push; child completion must not mutate the creator's stack. */
    StruisScopedPopCreatorCommand();
    pthread_t child;
    error=p->session?pthread_create(&child,NULL,StruisScopedRun,p):ENOMEM;
    if(!error) pthread_detach(child);
    else {
        /* no child started: creator still owns every transferred allocation */
        pid_t failed=p->scopedPid;
        StruisScopedDiscard(p); resetEnvironment(failed); StruisCommandScopeLaunchFailed(failed,error);
    }
    pthread_setcancelstate(oldCancel,NULL); return error;
}
/* Trusted outer stage wraps these around StageEnter; it owns borrowed FILEs. */
static __thread sessionParameters *StruisScopedPreviousSession;
static __thread FILE *StruisScopedPreviousInput, *StruisScopedPreviousOutput, *StruisScopedPreviousError;
static __thread void *StruisScopedPreviousContext;
int StruisIosCommandScopeBegin(FILE *input, FILE *output, FILE *errorStream, void *context) {
    if(!input || !output || !errorStream || StruisCommandScopeEnabled()) return EINVAL;
    sessionParameters temporary;
    sessionParameters *source=currentSession;
    if(!source) { initSessionParameters(&temporary); source=&temporary; }
    sessionParameters *copy=StruisScopedSessionCopy(source);
    if(source==&temporary) { for(int i=0;i<temporary.numCommandsAllocated;i++) free(temporary.commandName[i]); free(temporary.commandName); }
    if(!copy) return ENOMEM;
    /* RuntimeCommand sets its ios PID environment before stage entry. Capture
       that map before Begin selects a new root ID; ambient environ is different.
       This owned snapshot cannot alias a slot reset by storeEnvironment. */
    char **environmentSnapshot=StruisScopedEnvironmentCopy(environmentVariables(ios_currentPid()));
    if(!environmentSnapshot) { StruisScopedSessionDestroy(copy); return ENOMEM; }
    int error=StruisCommandScopeBegin();
    if(error) { StruisScopedEnvironmentDestroy(environmentSnapshot); StruisScopedSessionDestroy(copy); return error; }
    StruisScopedPreviousSession=currentSession;
    StruisScopedPreviousInput=thread_stdin; StruisScopedPreviousOutput=thread_stdout; StruisScopedPreviousError=thread_stderr; StruisScopedPreviousContext=thread_context;
    currentSession=copy;
    copy->stdin=input; copy->stdout=output; copy->stderr=errorStream; copy->context=context;
    thread_stdin=input; thread_stdout=output; thread_stderr=errorStream; thread_context=context;
    storeEnvironment(environmentSnapshot);
    StruisScopedEnvironmentDestroy(environmentSnapshot);
    return 0;
}
int StruisIosCommandScopeEnd(void) {
    int error=StruisCommandScopeCanEnd();
    if(error) return error; /* a timed-out/live child keeps this owner retained */
    resetEnvironment(ios_currentPid());
    error=StruisCommandScopeEnd();
    if(error) return error;
    StruisScopedSessionDestroy(currentSession); currentSession=StruisScopedPreviousSession; StruisScopedPreviousSession=NULL;
    thread_stdin=StruisScopedPreviousInput; thread_stdout=StruisScopedPreviousOutput; thread_stderr=StruisScopedPreviousError; thread_context=StruisScopedPreviousContext;
    StruisScopedPreviousInput=StruisScopedPreviousOutput=StruisScopedPreviousError=NULL; StruisScopedPreviousContext=NULL;
    return 0;
}
