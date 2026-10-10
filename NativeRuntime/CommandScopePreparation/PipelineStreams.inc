/* Apache-2.0. Included after actual ios_system child stream TLS declarations. */
int StruisIosCommandPipelineStreams(FILE **input, FILE **output, FILE **errorStream, void **context) {
    if(!input || !output || !errorStream || !context) return EINVAL;
    *input=*output=*errorStream=NULL; *context=NULL;
    if(!StruisCommandScopeEnabled()) return EINVAL;
    /* ios_dup2 leaves enclosing NREDIR selections pending in child TLS. Borrow
       that exact tuple without activating, clearing, or closing its FILEs. */
    FILE *selected[3]={child_stdin?child_stdin:thread_stdin,
                      child_stdout?child_stdout:thread_stdout,
                      child_stderr?child_stderr:thread_stderr};
    FILE *owned[3]={NULL,NULL,NULL};
    int error=0;
    for(int i=0;i<3;i++) if(!selected[i]) return EINVAL;
    if(fflush(selected[1])!=0) return errno?errno:EIO;
    if(selected[2]!=selected[1] && fflush(selected[2])!=0) return errno?errno:EIO;
    for(int i=0;i<3;i++) {
        for(int j=0;j<i;j++) if(selected[i]==selected[j]) { owned[i]=owned[j]; break; }
        if(owned[i]) continue;
        int fd=dup(fileno(selected[i]));
        if(fd<0) { error=errno?errno:EIO; break; }
        int flags=fcntl(fd,F_GETFL);
        if(flags<0) { error=errno?errno:EIO; close(fd); break; }
        const char *mode=(flags&O_ACCMODE)==O_RDWR?"r+b":((flags&O_ACCMODE)==O_RDONLY?"rb":"wb");
        owned[i]=fdopen(fd,mode);
        if(!owned[i]) { error=errno?errno:EIO; close(fd); break; }
    }
    if(error) {
        for(int i=0;i<3;i++) if(owned[i]) {
            int prior=0; for(int j=0;j<i;j++) if(owned[i]==owned[j]) prior=1;
            if(!prior) fclose(owned[i]);
        }
        return error;
    }
    *input=owned[0]; *output=owned[1]; *errorStream=owned[2]; *context=thread_context;
    /* Caller closes each distinct returned FILE once, on every result path.
       These duplicates keep timeout stages independent of shell restoration. */
    return 0;
}
