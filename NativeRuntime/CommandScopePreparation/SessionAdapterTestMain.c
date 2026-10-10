/* Apache-2.0. Executes generated C allocation/FILE/lifecycle paths; no ObjC evidence. */
extern int optreset; extern __thread int __db_getopt_reset; /* pinned BSD getopt.c */
static int fail_create;
static int live_allocations;
static int fail_duplicate;
static void *tracked_malloc(size_t count) { void *p=malloc(count);if(p)__atomic_add_fetch(&live_allocations,1,__ATOMIC_SEQ_CST);return p; }
static void *tracked_calloc(size_t count,size_t size) { void *p=calloc(count,size);if(p)__atomic_add_fetch(&live_allocations,1,__ATOMIC_SEQ_CST);return p; }
static char *tracked_strdup(const char *source) { if(fail_duplicate>0 && --fail_duplicate==0)return NULL;char *p=strdup(source);if(p)__atomic_add_fetch(&live_allocations,1,__ATOMIC_SEQ_CST);return p; }
static void tracked_free(void *p) { if(p)__atomic_sub_fetch(&live_allocations,1,__ATOMIC_SEQ_CST);free(p); }
#define malloc tracked_malloc
#define calloc tracked_calloc
#define strdup tracked_strdup
#define free tracked_free
static int checked_create(pthread_t *thread, const pthread_attr_t *attrs, void *(*entry)(void *), void *argument) {
    if(fail_create) return EAGAIN;
    return pthread_create(thread,attrs,entry,argument);
}
static void initSessionParameters(sessionParameters *session) {
    memset(session,0,sizeof(*session));session->numCommandsAllocated=1;
    session->commandName=calloc(1,sizeof(char*));session->commandName[0]=calloc(NAME_MAX,1);
}
static void *StruisScopedRun(void *parameters);
#define pthread_create checked_create
/* SELECTED_ADAPTER_INSERT */
#undef pthread_create
static void *StruisScopedRun(void *parameters) {
    functionParameters *p=parameters;
    assert(StruisCommandScopeAdopt(p->scopedPid)==0);
    StruisScopedResetParser();
    currentSession=p->session;thread_stdin=p->stdin;thread_stdout=p->stdout;thread_stderr=p->stderr;thread_context=p->context;
    p->argv_ref=malloc(sizeof(char *)*(p->argc+1));for(int i=0;i<p->argc;i++)p->argv_ref[i]=p->argv[i];
    pthread_cleanup_push(StruisScopedCleanup,p);
    StruisCommandScopeResult(p->function(p->argc,p->argv));
    pthread_cleanup_pop(1);return NULL;
}
static int write_bytes(int argc, char **argv) {
    assert(argc==1 && strcmp(argv[0],"dd")==0);
    unsigned char bytes[]={0,1,255,128,9};
    assert(fwrite(bytes,1,sizeof(bytes),thread_stdout)==sizeof(bytes));
    return 42;
}
static char parsed_count[16]; static int parsed_operands;
static int parse_count(int argc,char **argv) {
    int ch;parsed_count[0]=0;
    while((ch=getopt(argc,argv,"c:"))!=-1) { if(ch!='c') return 2; snprintf(parsed_count,sizeof(parsed_count),"%s",optarg); }
    parsed_operands=argc-optind;return 0;
}
static void set_argv(functionParameters *p,const char *const *words,int count) {
    for(int i=0;i<p->argc;i++)free(p->argv[i]);free(p->argv);
    p->argc=count;p->argv=calloc((size_t)count+1,sizeof(char *));assert(p->argv);
    for(int i=0;i<count;i++){p->argv[i]=strdup(words[i]);assert(p->argv[i]);}
}
static int requested_status;
static int report_status(int argc,char **argv) { (void)argc;(void)argv;return requested_status; }
static int blocked_input(int argc,char **argv) {
    (void)argc;(void)argv;
    assert(strcmp(libc_getenv("HOME"),"caller-home")==0);
    assert(strcmp(libc_getenv("WORKSPACE"),"scoped-workspace")==0);
    return fgetc(thread_stdin)==EOF?1:42;
}
static functionParameters *parameters(FILE *input, FILE *output) {
    functionParameters *p=calloc(1,sizeof(*p));assert(p);
    p->argc=1;p->argv=calloc(2,sizeof(char *));assert(p->argv);p->argv[0]=strdup("dd");assert(p->argv[0]);
    p->stdin=input;p->stdout=output;p->stderr=output;p->context=NULL;p->dlHandle=RTLD_DEFAULT;
    p->isPipeIn=input!=currentSession->stdin;p->isPipeOut=output!=currentSession->stdout;p->isPipeErr=false;
    p->session=currentSession;p->function=write_bytes;
    assert(currentSession->numCommand<currentSession->numCommandsAllocated);
    strcpy(currentSession->commandName[currentSession->numCommand++],"dd"); /* actual resolver's push */
    return p;
}
int main(void) {
    assert(StruisCommandScopeBegin()==0);storeEnvironment(environ);
    sessionParameters root={0};root.numCommandsAllocated=2;root.numCommand=1;root.commandName=calloc(2,sizeof(char*));
    for(int i=0;i<2;i++)root.commandName[i]=calloc(NAME_MAX,1);
    strcpy(root.commandName[0],"parent");
    root.stdin=tmpfile();root.stdout=tmpfile();root.stderr=root.stdout;root.global_errno=73;
    assert(root.stdin && root.stdout);currentSession=&root;thread_stdin=root.stdin;thread_stdout=thread_stderr=root.stdout;
    sessionParameters *copy=StruisScopedSessionCopy(&root);assert(copy && copy->commandName!=root.commandName && copy->commandName[0]!=root.commandName[0]);
    strcpy(copy->commandName[0],"child");assert(strcmp(root.commandName[0],"parent")==0 && root.global_errno==73);StruisScopedSessionDestroy(copy);
    int baseline=live_allocations;
    assert(ios_killpid(ios_currentPid(),0)==0);
    pid_t failed=ios_fork();assert(ios_killpid(failed,0)==EAGAIN);FILE *redirect=tmpfile();assert(redirect);int owned_fd=fileno(redirect),borrowed_fd=fileno(root.stdout);
    fail_create=1;assert(StruisScopedLaunch(parameters(root.stdin,redirect))==EAGAIN);fail_create=0;
    assert(live_allocations==baseline && root.numCommand==1);
    assert(fcntl(owned_fd,F_GETFD)==-1 && errno==EBADF);assert(fcntl(borrowed_fd,F_GETFD)>=0);
    int result;assert(StruisCommandScopeWait(failed,0,&result)==0 && result==EAGAIN);assert(ios_killpid(failed,0)==ESRCH);
    pid_t pending[128];int pendingCount=0;
    for(int i=0;i<128;i++) {pid_t id=StruisCommandScopeFork();if(id<0)break;pid_t captured;assert(StruisCommandScopeCapture(&captured)==0 && captured==id);pending[pendingCount++]=id;}
    assert(pendingCount>0 && pendingCount<128);
    redirect=tmpfile();assert(redirect);owned_fd=fileno(redirect);
    assert(StruisScopedLaunch(parameters(root.stdin,redirect))==EAGAIN);
    assert(live_allocations==baseline && root.numCommand==1 && fcntl(owned_fd,F_GETFD)==-1 && errno==EBADF);
    for(int i=0;i<pendingCount;i++) {StruisCommandScopeLaunchFailed(pending[i],EAGAIN);assert(StruisCommandScopeWait(pending[i],0,&result)==0 && result==EAGAIN);}
    pid_t child=ios_fork();assert(StruisScopedLaunch(parameters(root.stdin,root.stdout))==0);
    assert(StruisCommandScopeWait(child,0,&result)==0 && result==42);
    assert(live_allocations==baseline && root.numCommand==1);
    /* Each scoped command starts with a fresh BSD getopt scan, as the pinned
       run_function does; an option-taking command must not shift the next
       command's operands. */
    const char *const headWords[]={"head","-c","1024","input.bin"},*const catWords[]={"cat","first.bin","rest.bin"};
    for(int round=0;round<2;round++) {
        pid_t parsed=ios_fork();functionParameters *p=parameters(root.stdin,root.stdout);p->function=parse_count;
        if(round==0) set_argv(p,headWords,4); else set_argv(p,catWords,3);
        assert(StruisScopedLaunch(p)==0);ios_waitpid(parsed);assert(ios_getCommandStatus()==0);
        if(round==0) assert(strcmp(parsed_count,"1024")==0 && parsed_operands==1);
        else assert(parsed_count[0]==0 && parsed_operands==2);
        assert(live_allocations==baseline && root.numCommand==1);
    }
    /* RuntimeCommand.m order: launch returns admission only; the actual
       child status is read after the generated wait publishes it. */
    const int statuses[]={0,1,42,130,127};
    for(unsigned i=0;i<sizeof(statuses)/sizeof(statuses[0]);i++) {
        requested_status=statuses[i];pid_t command=ios_fork();
        functionParameters *p=parameters(root.stdin,root.stdout);p->function=report_status;
        assert(StruisScopedLaunch(p)==0);ios_waitpid(command);
        assert(ios_getCommandStatus()==statuses[i]);
        assert(StruisCommandScopeWait(command,1,&result)==ECHILD); /* consumed once */
        assert(live_allocations==baseline && root.numCommand==1);
    }
    assert(root.global_errno==73 && fcntl(borrowed_fd,F_GETFD)>=0); /* group FILE live after command */
    unsigned char visible[5];assert(pread(borrowed_fd,visible,5,0)==5 && visible[2]==255);
    assert(fflush(root.stdout)==0 && fseek(root.stdout,0,SEEK_SET)==0);
    unsigned char bytes[5];assert(fread(bytes,1,5,root.stdout)==5);
    assert(bytes[0]==0 && bytes[1]==1 && bytes[2]==255 && bytes[3]==128 && bytes[4]==9);
    assert(StruisCommandScopeCanEnd()==0);resetEnvironment(ios_currentPid());assert(StruisCommandScopeEnd()==0);
    FILE *previousIn=tmpfile(),*previousOut=tmpfile(),*previousErr=tmpfile();assert(previousIn && previousOut && previousErr);
    int previousContext=7,stageContext=8;
    thread_stdin=previousIn;thread_stdout=previousOut;thread_stderr=previousErr;thread_context=&previousContext;currentSession=&root;
    int inputPipe[2];assert(pipe(inputPipe)==0);FILE *stageIn=fdopen(inputPipe[0],"r");FILE *stageOut=tmpfile(),*stageErr=tmpfile();assert(stageIn && stageOut && stageErr);
    assert(setenv("HOME","ambient-home",1)==0 && setenv("WORKSPACE","ambient-workspace",1)==0);
    storeEnvironment(environ); /* actual legacy caller PID map */
    assert(ios_setenv("HOME","caller-home",1)==0 && ios_setenv("WORKSPACE","caller-workspace",1)==0);
    char **callerEnvironment=environmentVariables(ios_currentPid());
    baseline=live_allocations;
    fail_duplicate=2;assert(StruisIosCommandScopeBegin(stageIn,stageOut,stageErr,&stageContext)==ENOMEM);
    assert(!StruisCommandScopeEnabled() && live_allocations==baseline && currentSession==&root);
    assert(environmentVariables(ios_currentPid())==callerEnvironment);
    assert(thread_stdin==previousIn && thread_stdout==previousOut && thread_stderr==previousErr && thread_context==&previousContext);
    assert(StruisIosCommandScopeBegin(stageIn,stageOut,stageErr,&stageContext)==0);
    assert(environmentVariables(ios_currentPid())!=callerEnvironment);
    assert(strcmp(libc_getenv("HOME"),"caller-home")==0 && strcmp(libc_getenv("WORKSPACE"),"caller-workspace")==0);
    assert(ios_setenv("WORKSPACE","scoped-workspace",1)==0);
    assert(strcmp(getenv("HOME"),"ambient-home")==0 && strcmp(getenv("WORKSPACE"),"ambient-workspace")==0);
    assert(currentSession!=&root && thread_stdin==stageIn && thread_stdout==stageOut && thread_stderr==stageErr && thread_context==&stageContext);
    assert(StruisIosCommandScopeBegin(root.stdin,root.stdout,root.stderr,NULL)==EINVAL); /* nested entry denied without mutation */
    assert(thread_stdin==stageIn && thread_stdout==stageOut && thread_stderr==stageErr && thread_context==&stageContext);
    pid_t blockedId=ios_fork();functionParameters *blockedParameters=parameters(stageIn,stageOut);blockedParameters->stderr=stageErr;blockedParameters->function=blocked_input;
    assert(StruisScopedLaunch(blockedParameters)==0);
    pthread_t blockedThread;do {blockedThread=StruisCommandScopeThread(blockedId);} while(!blockedThread);
    assert(StruisIosCommandScopeEnd()==EBUSY); /* stream lifetime retained */
    assert(pthread_cancel(blockedThread)==0);
    assert(StruisCommandScopeWait(blockedId,0,&result)==0 && result==127);
    assert(StruisIosCommandScopeEnd()==0);
    assert(environmentVariables(ios_currentPid())==callerEnvironment);
    assert(strcmp(libc_getenv("HOME"),"caller-home")==0 && strcmp(libc_getenv("WORKSPACE"),"caller-workspace")==0);
    assert(strcmp(getenv("HOME"),"ambient-home")==0 && strcmp(getenv("WORKSPACE"),"ambient-workspace")==0);
    assert(live_allocations==baseline && currentSession==&root);
    assert(thread_stdin==previousIn && thread_stdout==previousOut && thread_stderr==previousErr && thread_context==&previousContext);
    assert(fputc('a',previousOut)=='a' && fflush(previousOut)==0);unsigned char restoredByte;assert(pread(fileno(previousOut),&restoredByte,1,0)==1 && restoredByte=='a');
    assert(fcntl(fileno(stageIn),F_GETFD)>=0 && fcntl(fileno(stageOut),F_GETFD)>=0 && fcntl(fileno(stageErr),F_GETFD)>=0);
    fclose(stageIn);close(inputPipe[1]);fclose(stageOut);fclose(stageErr);
    assert(StruisIosCommandScopeBegin(root.stdin,root.stdout,root.stderr,&stageContext)==0);
    assert(strcmp(libc_getenv("WORKSPACE"),"caller-workspace")==0);
    assert(StruisIosCommandScopeEnd()==0);
    resetEnvironment(ios_currentPid());
    assert(thread_stdin==previousIn && thread_stdout==previousOut && thread_stderr==previousErr && thread_context==&previousContext);
    fclose(previousIn);fclose(previousOut);fclose(previousErr);
    fclose(root.stdin);fclose(root.stdout);for(int i=0;i<2;i++)free(root.commandName[i]);free(root.commandName);
    assert(live_allocations==0);
    puts("PASS: actual selected generated C SessionAdapter deep session; caller HOME/WORKSPACE captured independently of ambient environment, inherited by child, and restored after End; real pthread-create failure injection cleans owned FILE and allocations; borrowed group FILE survives binary command; launch admission is separate from exact waited status 0/1/42/130/127; fresh pinned getopt scan per scoped command; exact redirected TLS restoration after cancellation; nested entry denial; no session result mixing");
}
