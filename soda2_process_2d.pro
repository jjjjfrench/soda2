PRO soda2_process_2d, op, textwidgetid=textwidgetid
   ;PRO to make 'spectra' files for a 2D probe, and save them
   ;in IDL's native binary format.  This version places particles
   ;individually in the appropriate time period, rather than the 
   ;entire buffer.  Limited to probes with absolute time, i.e. 
   ;CIP and Fast2D probes.
   ;Aaron Bansemer, NCAR, 2009.
   ;Copyright © 2016 University Corporation for Atmospheric Research (UCAR). All rights reserved.

   
   IF n_elements(textwidgetid) eq 0 THEN textwidgetid=0
   
   ;The current expected structure of op is:
   ;op={fn:fn, date:date, starttime:hms2sfm(starttime), stoptime:hms2sfm(stoptime), format:format, $
   ;subformat:subformat, probetype:probetype, res:res, endbins:endbins, arendbins:arendbins, rate:rate, $
   ;smethod:smethod, pth:pth, particlefile:0, inttime_reject:inttime_reject, reconstruct:1, stuckbits:0, water:water,$
   ;fixedtas:fixedtas, outdir:outdir, project:project, timeoffset:timeoffset, armwidth:armwidth, $
   ;numdiodes:numdiodes, greythresh:greythresh}
  
;presolve_all
;profiler,/reset
;profiler  
;profiler,/system
  
   
   soda2_update_op,op
   pop=ptr_new(op)      ;make a pointer to this for all other programs, these are constants
   ;Keep miscellaneous stuff here, things that change during processing
   misc={f2d_remainder:ulon64arr(512), f2d_remainder_slices:0, yres:op.yres, lastbufftime:0D, $
         nimages:0, imagepointers:lon64arr(500), lastclock:0d, lastparticlecount:0L, maxsfm:0D}    
   pmisc=ptr_new(misc)  ;a different pointer, for stuff that changes 
   
   ;====================================================================================================
   ;====================================================================================================
   ;Initialize variables.  
   ;====================================================================================================
   ;====================================================================================================
   numrecords=(op.stoptime-op.starttime)/op.rate + 1   ;Number of records that will be saved
   numbins=n_elements(op.endbins)-1 
   numarbins=n_elements(op.arendbins)-1 
   
   numintbins=40 
   iminpower=-7      ;lowest bin exponent
   imaxpower=1       ;highest bin exponent
   intendbins=10^((findgen(numintbins+1)/numintbins)*(imaxpower-iminpower)+iminpower)        ;log-spaced endbins from iminpower to maxpower
   intmidbins=10^(((findgen(numintbins)+0.5)/numintbins) *(imaxpower-iminpower)+iminpower)   ;midbins
   
   numzdbins=163 
   
   d={numrecords:numrecords,$
   time:op.starttime + op.rate*dindgen(numrecords) ,$    ;This is the start time for each record
   
   ;PSD
   numbins:numbins ,$
   numarbins:numarbins ,$
   count_accepted:lonarr(numrecords) ,$
   count_rejected:lonarr(numrecords,7) ,$
   count_missed:lonarr(numrecords) ,$
   missed_hist:fltarr(numrecords,50),$
   spec2d:fltarr(numrecords, numbins, numarbins) ,$
   spec2d_aspr:fltarr(numrecords, numbins, numarbins) ,$
   spec2d_orientation:fltarr(numrecords, numbins, 18) ,$
   ;JPL temporary
   spec1d_spherical:fltarr(numrecords, numbins) ,$
   spec1d_mediumprolate:fltarr(numrecords, numbins) ,$
   spec1d_oblate:fltarr(numrecords, numbins) ,$
   spec1d_maximumprolate:fltarr(numrecords, numbins) ,$
 
   ;Interarrival
   numintbins:numintbins ,$
   iminpower:iminpower  ,$    ;lowest bin exponent
   imaxpower:imaxpower   ,$    ;highest bin exponent
   intendbins:intendbins ,$
   intmidbins:intmidbins ,$
   intspec_all:fltarr(numrecords,numintbins) ,$       ;interarrival time spectra for all (rejected too) particles
   intspec_accepted:fltarr(numrecords,numintbins) ,$  ;interarrival time spectra for accepted particles
     
   ;Zd (from Korolev corrections)
   numzdbins:numzdbins ,$
   zdendbins:findgen(numzdbins)*0.05-0.025 ,$
   zdmidbins:findgen(numzdbins)*0.05 ,$
   zdspec:lonarr(numbins,numzdbins) ,$
     
   ;Misc
   tas:fltarr(numrecords) ,$
   poisson_fac:fltarr(numrecords,3) ,$ ;the coefficients into the double poisson fit
   corr_fac:fltarr(numrecords)+1 ,$    ;Poisson correction factor
   intcutoff:fltarr(numrecords), $   ;+intendbins[0]
   deadtime:fltarr(numrecords), $
   hist3d:fltarr(numbins,numarbins,numarbins) $  ;Histogram of area ratio, axis ratio, and size
   }
   ;Not needed in structure
   numbuffsaccepted=intarr(numrecords)
   numbuffsrejected=intarr(numrecords)
   dhist=lonarr(numrecords,op.numdiodes)

   ;Set up the particle structure.  
   num2process=10000000L ;Limit to reduce memory consumption
   basestruct={bufftime:0d, probetime:0d, reftime:0d, size:0.0, xsize:0.0, ysize:0.0, ar:0.0, aspr:0.0, area:0.0, $
               allin:0b, tas:0s, zd:0.0, missed:0.0, overloadflag:0b, orientation:0.0, perimeterarea:0.0}
   x=replicate(basestruct, num2process)
 
   
   ;====================================================================================================
   ;====================================================================================================
   ;Get tas from PTH file, if applicable
   ;====================================================================================================
   ;====================================================================================================
   got_pth=0
   IF file_test(op.pth) THEN BEGIN
      suffix=(strsplit(op.pth,'.',/extract))[-1]
      ;IDL sav files      
      IF (suffix eq 'dat') or (suffix eq 'sav') THEN BEGIN      
         restore,op.pth
         IF total(d.time - data.time) ne 0 THEN stop,'PTH time does not match.'
         pth_tas=data.tas
         got_pth=1
      ENDIF
      ;ASCII or CSV files, assumes time and tas in first two columns
      IF (suffix eq 'txt') or (suffix eq 'csv') THEN BEGIN
         pth_tas=fltarr(numrecords)
         v=''
         openr,lun,op.pth,/get_lun
         on_ioerror, bad  ;Use to suppress type conversion errors
         REPEAT BEGIN
            readf,lun,v
            fields=float(strsplit(v, '[ ,' + STRING(9B) + ']+', /regex, /extract))
            i=(round(fields[0])-op.starttime)/op.rate ;find index for each variable
            ;Fill TAS array, don't bother with averaging
            IF (i ge 0) and (i lt numrecords) and (fields[1] gt 0) and (fields[1] lt 500) THEN pth_tas[i]=fields[1]
            bad:dummy=0
         ENDREP UNTIL eof(lun)
         on_ioerror, null
         free_lun,lun
         got_pth=1
      ENDIF
   ENDIF ELSE BEGIN
      pth_tas=fltarr(numrecords)
      print,'Can not find TAS, using default values'
   ENDELSE
      
   ;====================================================================================================
   ;====================================================================================================
   ;Build index of buffers for all files.  
   ;====================================================================================================
   ;====================================================================================================
   
   
   firstfile=1
   FOR i=0,n_elements(op.fn)-1 DO BEGIN
      y=soda2_buildindex(op.fn[i], pop)      
      IF y.error eq 0 THEN BEGIN
         IF firstfile THEN BEGIN
            ;Create arrays
            bufftime=y.bufftime
            buffdate=y.date
            buffpoint=y.pointer
            bufffile=bytarr(y.count)+i
         ENDIF ELSE BEGIN
            ;Concatenate arrays if there is more than one file
            IF op.format eq 'SPEC' THEN stop, 'Multiple files not supported with SPEC format, need to concatenate raw files first'
            bufftime=[bufftime, y.bufftime]
            buffdate=[buffdate, y.date]
            buffpoint=[buffpoint,y.pointer]
            bufffile=[bufffile,bytarr(y.count)+i]
         ENDELSE
         firstfile=0
      ENDIF ELSE IF y.error eq 1 THEN stop,'Error on build index, check probe ID set correctly.'
   ENDFOR
   
   ;Set up particlefile
   lun_pbp=2
   ncdf_offset=0L
   IF op.particlefile eq 1 THEN BEGIN
      fn_pbp=soda2_filename(op,op.shortname,extension='.pbp.nc')
      id=ncdf_create(fn_pbp,/clobber)
      ;Define the x-dimension, should be used in all variables
      xdimid=ncdf_dimdef(id,'Time',/unlimited)
      
      ;These are for ncplot compatibility
      opnames=tag_names(op)
      flightdate=strmid(op.date,0,2)+'/'+strmid(op.date,2,2)+'/'+strmid(op.date,4,4)
      
      tb='0000'+strtrim(string(sfm2hms(op.starttime)),2)
      te='0000'+strtrim(string(sfm2hms(op.stoptime)),2)
      starttimestr=strmid(tb,5,2,/r)+':'+strmid(tb,3,2,/r)+':'+strmid(tb,1,2,/r)
      stoptimestr=strmid(te,5,2,/r)+':'+strmid(te,3,2,/r)+':'+strmid(te,1,2,/r)
      intervalstr=starttimestr+'-'+stoptimestr
      
      ;Create global attributes
      ncdf_attput,id,'Source','SODA-2 OAP Processing Software',/global
      ncdf_attput,id,'FlightDate',flightdate[0],/global
      ncdf_attput,id,'DateProcessed',systime(),/global
      ncdf_attput,id,'TimeInterval',intervalstr,/global
      opnames=tag_names(op)                  
      FOR i=0,n_elements(opnames)-1 DO BEGIN
         IF size(op.(i), /type) eq 7 THEN BEGIN  ;Look for strings, must be handled differently
            IF string(op.(i)[0]) eq '' THEN op.(i)[0]='none' ;To avoid an ncdf error (empty string)
            ncdf_attput,id,opnames[i],op.(i)[0],/global  ;Only put first element for string
         ENDIF ELSE ncdf_attput,id,opnames[i],op.(i),/global   ;Non-strings, all elements      
      ENDFOR
      
      tagnames=['time', 'ipt', 'diam', 'xsize', 'ysize', 'arearatio', 'aspectratio', 'area', 'perimeterarea','allin', $
                'zd', 'missed', 'overload','orientation']
      longname=['UTC time','Interarrival Time','Particle Diameter','X-size (across array)','Y-size (along airflow)',$
                'Area Ratio','Aspect Ratio','Pixel Area','Perimeter Pixel Area','All-in Flag','Z position','Missed Particles','Overload Flag','Orientation']
      units=['seconds','seconds','microns','microns','microns','unitless','unitless','pixels','pixels','boolean','microns','number','degrees','boolean']
      FOR i=0,n_elements(tagnames)-1 DO BEGIN
         varid=ncdf_vardef(id,tagnames[i],xdimid,/float)
         ncdf_attput,id,varid,'longname',longname[i]
         ncdf_attput,id,varid,'units',units[i]
      ENDFOR
      ncdf_control,id,/endef                ;put in data mode 
      lun_pbp=id
   ENDIF
   IF op.particlefile eq 2 THEN BEGIN
      fn_pbp=soda2_filename(op,op.shortname,extension='.pbp')
      close,lun_pbp
      openw,lun_pbp,fn_pbp
      printf,lun_pbp,'Timestamp(UTC)  IPT(s)  Diam(um)  AreaRatio  Allin(bool)  zd  missed'
   ENDIF
    
   ;====================================================================================================
   ;====================================================================================================
   ;Process buffers that fall into the specified time period.  Write individual
   ;particle data to a structure.
   ;====================================================================================================
   ;====================================================================================================
   
   ;Make sure buffers are sorted
   numbuffs=n_elements(bufftime)
   startdate=julday(strmid(op.date,0,2), strmid(op.date,2,2), strmid(op.date,4,4))
   IF abs(buffdate[0]-startdate) gt 5 THEN BEGIN
      ;Some probes do not have the date right, just use the first one in this case
      caldat,startdate,usermo,userday,useryear
      caldat,buffdate[0],buffmo,buffday,buffyear
      startdate=buffdate[0]
      print,usermo,userday,useryear,buffmo,buffday,buffyear,format='(i3,i3,i5,i5,i3,i5)'
      print,'Probe date stamps do not match user date, continuing...'
   ENDIF   
   bufftime=bufftime+86400d*(buffdate-startdate[0])  ;Midnight crossings  
   s=sort(bufftime)   
   bufftime=bufftime[s]
   buffpoint=buffpoint[s]
   bufffile=bufffile[s]
   buffindex=long((bufftime-op.starttime)/op.rate)  ;keep these for output only
   imagepointers=0  ;Used for SPEC probes only, pointers to each image in a buffer
   
   firstbuff=max(where(bufftime lt op.starttime)) > 0
   lastbuff=min(where(bufftime gt op.stoptime,nlb))
   IF nlb eq 0 THEN lastbuff=numbuffs-1
   IF (lastbuff-firstbuff) le 0 THEN BEGIN
      print,'No buffers in specified time range'    
      return
   ENDIF
   currentfile=-1
   
   ;lastbuffertime=0   
   lastpercentcomplete=0
   istop=-1L
   inewbuffer=lonarr(lastbuff-firstbuff+1)
   FOR i=firstbuff,lastbuff DO BEGIN
      ;Open new file if needed
      IF currentfile ne bufffile[i] THEN BEGIN
         close,1
         openr,1,op.fn[bufffile[i]]
         currentfile=bufffile[i]
      ENDIF
      
      ;Read in buffer
      point_lun,1,buffpoint[i]
      b=soda2_read2dbuffer(1,pop)
      b.time=bufftime[i]   ;In case time changed due to midnight crossing
      timeindex=long((b.time-op.starttime)/op.rate)>0<(numrecords-1)   ;Index each buffer into right time period
      
      ;Commented out b/c time indexing should account for offsets in truetime/reftime
      ;To-do....
      ;IF b.overload gt 0 THEN BEGIN
      ;   timeindex=long((b.time-op.starttime)/op.rate)
      ;   IF (timeindex ge 0) and (timeindex lt numrecords) THEN deadtime[timeindex]=deadtime[timeindex]+b.overload
      ;ENDIF
      
      ;Update miscellaneous
      ;*************Update misc.yres here, not yet implemented
      
      ;Process
      IF (*pop).format eq 'SPEC' THEN BEGIN
         (*pmisc).nimages=y.numimages[i]
         IF (*pmisc).nimages gt 0 THEN $
            (*pmisc).imagepointers=i*y.buffsize + y.imagep[(y.firstp[i]):(y.firstp[i]+y.numimages[i]-1)]
      ENDIF    
      p=soda2_processbuffer(b,pop,pmisc)
      dhist[timeindex,*]=dhist[timeindex,*]+p.dhist
   
      IF p.rejectbuffer eq 0 THEN BEGIN
        numbuffsaccepted[timeindex]=numbuffsaccepted[timeindex]+1
        ;Write data to structure
        n=n_elements(p.size)
        istart=istop+1
        inewbuffer[i-firstbuff]=istart  ;Save these start positions
        istop=istop+n
        
        x[istart:istop].bufftime=b.time
        x[istart:istop].probetime=p.probetime
        x[istart:istop].reftime=p.reftime
        x[istart:istop].size=p.size
        x[istart:istop].xsize=p.xsize
        x[istart:istop].ysize=p.ysize
        x[istart:istop].ar=p.ar
        x[istart:istop].aspr=p.aspr
        x[istart:istop].area=p.area_orig 
        x[istart:istop].perimeterarea=p.perimeterarea 
        x[istart:istop].allin=p.allin
        x[istart:istop].tas=b.tas
        x[istart:istop].zd=p.zd
        x[istart:istop].missed=p.missed
        x[istart:istop].overloadflag=p.overloadflag
        x[istart:istop].orientation=p.orientation
        ;x[istart:istop].nsep=p.nsep  ;now using keeplargest option for detection of multi-particles
   
        ;Feedback to user
        percentcomplete=fix(float(i-firstbuff)/(lastbuff-firstbuff)*100)
        IF percentcomplete ne lastpercentcomplete THEN BEGIN
            infoline=strtrim(string(percentcomplete))+'%'
            IF textwidgetid ne 0 THEN widget_control,textwidgetid,set_value=infoline,/append ELSE print,infoline
        ENDIF
        lastpercentcomplete=percentcomplete
      ENDIF ELSE BEGIN
         numbuffsrejected[timeindex]=numbuffsrejected[timeindex]+1
      ENDELSE
      IF (istop+500) gt num2process THEN BEGIN
         ;Memory limit reached, process particles and reset arrays
         soda2_particlesort, pop, x, d, istop, inewbuffer, lun_pbp, ncdf_offset
         ncdf_offset=ncdf_offset + istop + 1
         istop=-1L         
      ENDIF
      
   ENDFOR
         
   IF istop lt 0 THEN return
   infoline='Sorting Particles...'
   IF textwidgetid ne 0 THEN widget_control,textwidgetid,set_value=infoline,/append ELSE print,infoline
   soda2_particlesort, pop, x, d, istop, inewbuffer, lun_pbp, ncdf_offset
   close,1


   ;====================================================================================================
   ;====================================================================================================   
   ;Compute concentration, save data
   ;====================================================================================================
   ;====================================================================================================

   spec1d=total(d.spec2d,3)

   numbins=n_elements(op.endbins)-1
   midbins=(float(op.endbins[0:numbins-1])+op.endbins[1:numbins])/2.0
   binwidth=op.endbins[1:numbins]-op.endbins[0:numbins-1]
   sa=fltarr(numbins)
   FOR i=0,numbins-1 DO sa[i]=soda2_samplearea(midbins[i], op.res, op.armwidth, op.numdiodes, op.reconstruct, op.smethod, op.wavelength, centerin=op.centerin)

   ;Assume probe is always active, minus deadtime
   IF op.ignoredeadtime eq 1 THEN activetime=fltarr(numrecords)+op.rate ELSE activetime=(fltarr(numrecords)+op.rate-d.deadtime)>0 
   IF (got_pth eq 1) THEN d.tas=pth_tas
   sv=sa*d.tas*activetime
   
   conc1d=fltarr(numrecords, numbins)  ;size spectra
   ;JPL temp
   conc1d_spherical=fltarr(numrecords, numbins)
   conc1d_mediumprolate=fltarr(numrecords, numbins)
   conc1d_oblate=fltarr(numrecords, numbins)
   conc1d_maximumprolate=fltarr(numrecords, numbins) 
   ;Orientation
   orientation_index=fltarr(numrecords, numbins)
   FOR i=0L,numrecords-1 DO BEGIN
      spec1d[i,*]=spec1d[i,*]*(d.corr_fac[i] > 1.0)          ;Make the correction
      d.spec2d[i,*,*]=d.spec2d[i,*,*]*(d.corr_fac[i] > 1.0) 
      d.spec2d_aspr[i,*,*]=d.spec2d_aspr[i,*,*]*(d.corr_fac[i] > 1.0)
      IF d.tas[i]*activetime[i] gt 0 THEN BEGIN
         conc1d[i,*]=spec1d[i,*]/(sa*d.tas[i]*activetime[i])/(binwidth/1.0e6) 
         ;JPL temp
         conc1d_spherical[i,*]=d.spec1d_spherical[i,*]/(sa*d.tas[i]*activetime[i])/(binwidth/1.0e6) 
         conc1d_mediumprolate[i,*]=d.spec1d_mediumprolate[i,*]/(sa*d.tas[i]*activetime[i])/(binwidth/1.0e6) 
         conc1d_oblate[i,*]=d.spec1d_oblate[i,*]/(sa*d.tas[i]*activetime[i])/(binwidth/1.0e6) 
         conc1d_maximumprolate[i,*]=d.spec1d_maximumprolate[i,*]/(sa*d.tas[i]*activetime[i])/(binwidth/1.0e6) 
         ;Orientation index computation from histograms
         FOR j=0,numbins-1 DO BEGIN
            omax=max(d.spec2d_orientation[i,j,*], imax)
            totspec=total(d.spec2d_orientation[i,j,*],/nan)
            IF totspec gt 50 THEN orientation_index[i,j]=float(omax)/totspec
         ENDFOR
      ENDIF
   ENDFOR

   data={op:op, time:d.time, tas:d.tas, midbins:midbins, activetime:activetime, Date_Processed:systime(), sa:sa, $
         intspec_all:d.intspec_all, intspec_accepted:d.intspec_accepted, intendbins:intendbins, intmidbins:intmidbins,$  
         count_rejected:d.count_rejected,count_accepted:d.count_accepted, count_missed:d.count_missed, $
         missed_hist:d.missed_hist, conc1d:conc1d, spec1d:spec1d, spec2d:d.spec2d, spec2d_aspr:d.spec2d_aspr,$
         corr_fac:d.corr_fac, poisson_fac:d.poisson_fac, intcutoff:d.intcutoff, zdspec:d.zdspec, zdendbins:d.zdendbins, zdmidbins:d.zdmidbins,$
         pointer:buffpoint, ind:buffindex, currentfile:bufffile, numbuffsaccepted:numbuffsaccepted, numbuffsrejected:numbuffsrejected, dhist:dhist,$
         hist3d:d.hist3d, spec2d_orientation:d.spec2d_orientation, orientation_index:orientation_index}
         ;, conc1d_spherical:conc1d_spherical, conc1d_mediumprolate:conc1d_mediumprolate, conc1d_oblate:conc1d_oblate, conc1d_maximumprolate:conc1d_maximumprolate }
  
   fn_out=soda2_filename(op,op.shortname)
   IF op.savfile eq 1 THEN BEGIN
      save,file=fn_out,data,/compress
      infoline='Saved file '+fn_out
      IF textwidgetid ne 0 THEN dummy=dialog_message(infoline,dialog_parent=textwidgetid,/info) ELSE print,infoline
   ENDIF
   
   IF op.particlefile ne 0 THEN BEGIN
      IF op.particlefile eq 1 THEN ncdf_close,lun_pbp
      IF op.particlefile eq 2 THEN close,lun_pbp
      infoline='Saved file '+fn_pbp
      IF textwidgetid ne 0 THEN dummy=dialog_message(infoline,dialog_parent=textwidgetid,/info) ELSE print,infoline
   ENDIF
   
   ptr_free, pop, pmisc

;profiler,/report  
END


