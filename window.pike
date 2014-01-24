//GUI handler.

//First color must be black.
constant defcolors="000000 00007F 007F00 007F7F 7F0000 7F007F 7F7F00 C0C0C0 7F7F7F 0000FF 00FF00 00FFFF FF0000 FF00FF FFFF00 FFFFFF"; //TODO: INI file this. (And stop reversing them.)
constant default_ts_fmt="%Y-%m-%d %H:%M:%S UTC";
array(GTK2.GdkColor) colors;

mapping(string:mapping(string:mixed)) channels=persist["color/channels"] || ([]);
constant deffont="Monospace 10";
mapping(string:mapping(string:mixed)) fonts=persist["window/font"] || (["display":(["name":deffont]),"input":(["name":deffont])]);
mapping(string:mapping(string:mixed)) numpadnav=persist["window/numpadnav"] || ([]); //Technically doesn't have to be restricted to numpad.
multiset(string) numpadspecial=persist["window/numpadspecial"] || (<"look", "glance", "l", "gl">); //Commands that don't get prefixed with 'go ' in numpadnav
mapping(string:object) fontdesc=([]); //Cache of PangoFontDescription objects, for convenience (pruned on any font change even if something else was using it)
array(mapping(string:mixed)) tabs=({ }); //In the same order as the notebook's internal tab objects
GTK2.Window mainwindow;
GTK2.Notebook notebook;
#if constant(COMPAT_SIGNAL)
GTK2.Button defbutton;
#endif
GTK2.Hbox statusbar;
array(object) signals;
int paused;
mapping(GTK2.MenuItem:string) menu=([]); //Retain menu items and the names of their callback functions
inherit statustext;

/* Each subwindow is defined with a mapping(string:mixed) - some useful elements are:

	//Each 'line' represents one line that came from the MUD. In theory, they might be wrapped for display, which would
	//mean taking up more than one display line, though currently this is not implemented.
	//Each entry must begin with a metadata mapping and then alternate between color and string, in that order.
	array(array(mapping|GTK2.GdkColor|string)) lines=({ });
	array(mapping|GTK2.GdkColor|string) prompt=({([])});
	GTK2.DrawingArea display;
	GTK2.ScrolledWindow maindisplay;
	GTK2.Adjustment scr;
	GTK2.Entry ef;
	GTK2.Widget page;
	array(string) cmdhist=({ });
	int histpos=-1;
	int passwordmode; //When 1, commands won't be saved.
	int lineheight; //Pixel height of a line of text
	int totheight; //Current height of the display
	mapping connection;
	string tabtext;
	int activity=0; //Set to 1 when there's activity, set to 0 when focus is on this tab
	array(object) signals; //Collection of gtksignal objects - replaced after code reload
	int selstartline,selstartcol,selendline,selendcol; //Highlight start/end positions. If no highlight, selstartline will not even exist.
*/
mapping(string:mixed) subwindow(string txt)
{
	mapping(string:mixed) subw=(["lines":({ }),"prompt":({([])}),"cmdhist":({ }),"histpos":-1]);
	tabs+=({subw});
	//Build the window
	notebook->append_page(subw->page=GTK2.Vbox(0,0)
		->add(subw->maindisplay=GTK2.ScrolledWindow((["hadjustment":GTK2.Adjustment(),"vadjustment":subw->scr=GTK2.Adjustment(),"background":"black"]))
			->add(subw->display=GTK2.DrawingArea())
			->set_policy(GTK2.POLICY_AUTOMATIC,GTK2.POLICY_ALWAYS)
		)
		->pack_end(subw->ef=GTK2.Entry(),0,0,0)
	->show_all(),GTK2.Label(subw->tabtext=txt))->set_current_page(sizeof(tabs)-1);
	setfonts(subw);
	#if constant(COMPAT_SIGNAL)
	subw->ef->set_activates_default(1);
	#endif
	subwsignals(subw);
	colorcheck(subw->ef,subw);
	call_out(redraw,0,subw);
	return subw;
}

/**
 * Return the subw mapping for the currently-active tab.
 */
mapping(string:mixed) current_subw() {return tabs[notebook->get_current_page()];}

/**
 * Get a suitable Pango font for a particular category. Will cache based on font name.
 *
 * @param	category	the category of font for which to collect the description
 * @return	PangoFontDescription	Font object suitable for GTK2
 */
GTK2.PangoFontDescription getfont(string category)
{
	string fontname=fonts[category]->name;
	return fontdesc[fontname] || (fontdesc[fontname]=GTK2.PangoFontDescription(fontname));
}

/**
 * Set/update fonts and font metrics
 *
 * @param subw Current subwindow
 */
void setfonts(mapping(string:mixed) subw)
{
	subw->display->modify_font(getfont("display"));
	subw->ef->modify_font(getfont("input"));
	mapping dimensions=subw->display->create_pango_layout("asdf")->index_to_pos(3);
	subw->lineheight=dimensions->height/1024; subw->charwidth=dimensions->width/1024;
}


/**
 * (Re)establish event handlers
 *
 * @param subw Current subwindow
 */
void subwsignals(mapping(string:mixed) subw)
{
	subw->signals=({
		gtksignal(subw->display,"expose_event",paint,subw),
		gtksignal(subw->scr,"changed",scrchange,subw),
		//gtksignal(subw->scr,"value_changed",lambda(mixed ... args) {write("value_changed: %O %O\n",subw->scr->get_value(),subw->scr->get_property("upper")-subw->scr->get_property("page size"));}),
		#if constant(COMPAT_SIGNAL)
		gtksignal(subw->ef,"key_press_event",keypress,subw),
		#else
		gtksignal(subw->ef,"key_press_event",keypress,subw,UNDEFINED,1),
		#endif
		gtksignal(subw->display,"button_press_event",mousedown,subw),
		gtksignal(subw->display,"button_release_event",mouseup,subw),
		gtksignal(subw->display,"motion_notify_event",mousemove,subw),
		gtksignal(subw->ef,"changed",colorcheck,subw),
		GTK2.GObject()->signal_stop && gtksignal(subw->ef,"paste_clipboard",paste,subw,UNDEFINED,1),
	});
	subw->display->add_events(GTK2.GDK_POINTER_MOTION_MASK|GTK2.GDK_BUTTON_PRESS_MASK|GTK2.GDK_BUTTON_RELEASE_MASK);
}

/**
 * Update the scroll bar's range
 */
void scrchange(object self,mapping subw)
{
	float upper=self->get_property("upper");
	//werror("upper %f, page %f, pos %f\n",upper,self->get_property("page size"),upper-self->get_property("page size"));
	#if constant(COMPAT_SCROLL)
	//On Windows, there's a problem with having more than 32767 of height. It seems to be resolved, though, by scrolling up to about 16K and then down again.
	//TODO: Solve this properly. Failing that, find the least flickery way to do this scrolling (would it still work if painting is disabled?)
	if (upper>32000.0) self->set_value(16000.0);
	#endif
	if (!paused) self->set_value(upper-self->get_property("page size"));
}

void paste(object self,mapping subw)
{
	//At this point, the clipboard contents haven't been put into the EF.
	//Preventing the normal behaviour depends on the widget having a
	//signal_stop() method, which was implemented in Pike 8.0.1+ and
	//7.8.820+. If that method is not available, the signal will not be
	//connected to (see above), so in this function, we assume that it
	//exists and can be used.
	string txt=self->get_clipboard(GTK2.Gdk_Atom("CLIPBOARD"))->wait_for_text();
	if (!txt || !has_value(txt,'\n')) return; //No text? Nothing will happen. One line of text? Let it go with the default.
	self->signal_stop("paste_clipboard"); //Prevent the full paste, we'll do it ourselves.
	array(string) lines=txt/"\n";
	sscanf(self->get_text(),"%"+self->get_position()+"s%s",string before,string after); //A bit hackish... get the text before and after the cursor :)
	enterpressed(subw,before+lines[0]);
	foreach (lines[1..<1],string l) enterpressed(subw,l);
	self->set_text(lines[-1]+after); self->set_position(sizeof(lines[-1]));
}

GTK2.Widget makestatus()
{
	statustxt->paused=GTK2.Label("<PAUSED>");
	statustxt->paused->set_size_request(statustxt->paused->size_request()->width,-1)->set_text(""); //Have it consume space for the PAUSED message even without having it
	return GTK2.Hbox(0,10)->add(statustxt->lbl=GTK2.Label(""))->add(statustxt->paused);
}

//Convert (x,y) into (line,col) - yes, that switches their order.
//Depends on the current scr->pagesize.
//Note that line and col may exceed the array index limits by 1 - equalling sizeof(subw->lines) or the size of the string at that line.
//A return value equal to the array/string size represents the prompt or the (implicit) newline at the end of the string.
/**
 *
 */
array(int) point_to_char(mapping subw,int x,int y)
{
	int line=(y-(int)subw->scr->get_property("page size"))/subw->lineheight;
	array l;
	if (line<0) line=0;
	if (line>=sizeof(subw->lines)) {line=sizeof(subw->lines); l=subw->prompt;}
	else l=subw->lines[line];
	string str=filter(l,stringp)*"";
	int pos=limit(0,(x-3)/subw->charwidth,sizeof(str));
	if (has_value(str[..pos-2],'\t')) //There are tabs in the line, figure out where we really are.
	{
		int realpos=0;
		for (int i=0;i<pos;++i)
		{
			if (str[i]=='\t') realpos+=8-realpos%8; else ++realpos;
			if (realpos>pos) return ({line,i});
		}
	}
	return ({line,pos});
}

/**
 * Clear any previous highlight, and highlight from (line1,col1) to (line2,col2)
 * Will trigger a repaint of all affected areas.
 * If line1==-1, will remove all highlight.
 */
void highlight(mapping subw,int line1,int col1,int line2,int col2)
{
	if (has_index(subw,"selstartline")) //There's a previous highlight. Clear it (by queuing draw for those lines).
	{
		int y1= min(subw->selstartline,subw->selendline)   *subw->lineheight;
		int y2=(max(subw->selstartline,subw->selendline)+1)*subw->lineheight;
		subw->display->queue_draw_area(0,subw->scr->get_property("page size")+y1,1<<30,y2-y1);
	}
	if (line1==-1) {m_delete(subw,"selstartline"); return;} //Unhighlight.
	subw->selstartline=line1; subw->selstartcol=col1; subw->selendline=line2; subw->selendcol=col2;
	int y1= min(line1,line2)   *subw->lineheight;
	int y2=(max(line1,line2)+1)*subw->lineheight;
	subw->display->queue_draw_area(0,subw->scr->get_property("page size")+y1,1<<30,y2-y1);
}

/**
 *
 */
void mousedown(object self,object ev,mapping subw)
{
	[int line,int col]=point_to_char(subw,(int)ev->x,(int)ev->y);
	highlight(subw,line,col,line,col);
	subw->mouse_down=1;
}

/**
 *
 */
void mouseup(object self,object ev,mapping subw)
{
	int mouse_down=m_delete(subw,"mouse_down"); //Destructive query
	if (!mouse_down) return; //Mouse wasn't registered as down, do nothing.
	[int line,int col]=point_to_char(subw,(int)ev->x,(int)ev->y);
	string content;
	if (mouse_down==1)
	{
		//Mouse didn't move between going down and going up. Consider it a click.
		highlight(subw,-1,0,0,0);
		//Go through the line clicked on. Find one single word in one single color, and that's
		//what was clicked on. TODO: Optionally permit the user to click on something with a
		//modifier key (eg Ctrl-Click) to execute something as a command - would play well with
		//help files highlighted in color, for instance.
		foreach ((line==sizeof(subw->lines))?subw->prompt:subw->lines[line],mixed x) if (stringp(x))
		{
			col-=sizeof(x); if (col>0) continue;
			col+=sizeof(x); //Go back to the beginning of this color block - we've found something.
			foreach (x/" ",string word)
			{
				col-=sizeof(word); if (col>0) continue;
				//We now have the exact word, delimited by color boundary and blank space.
				if (has_prefix(word,"http://") || has_prefix(word,"https://") || has_prefix(word,"www."))
					invoke_browser(word);
				return;
			}
		}
		//Couldn't find anything to click on.
		return;
	}
	if (subw->selstartline==line)
	{
		//Single-line selection: special-cased for simplicity.
		if (subw->selstartcol>col) [col,subw->selstartcol]=({subw->selstartcol,col});
		content=filter((line==sizeof(subw->lines))?subw->prompt:subw->lines[line],stringp)*""+"\n";
		content=content[subw->selstartcol..col-1];
	}
	else
	{
		if (subw->selstartline>line) [line,col,subw->selstartline,subw->selstartcol]=({subw->selstartline,subw->selstartcol,line,col});
		for (int l=subw->selstartline;l<=line;++l)
		{
			string curline=filter((l==sizeof(subw->lines))?subw->prompt:subw->lines[l],stringp)*""+"\n";
			if (l==subw->selstartline) content=curline[subw->selstartcol..];
			else if (l==line) content+=curline[..col-1];
			else content+=curline;
		}
	}
	highlight(subw,-1,0,0,0);
	subw->display->get_clipboard(GTK2.Gdk_Atom("CLIPBOARD"))->set_text(content,sizeof(content));
}

/**
 *
 */
void mousemove(object self,object ev,mapping subw)
{
	[int line,int col]=point_to_char(subw,(int)ev->x,(int)ev->y);
	string txt=sprintf("Line %d of %d",line,sizeof(subw->lines));
	catch
	{
		mapping meta = (line==sizeof(subw->lines) ? subw->prompt : subw->lines[line])[0];
		if (!mappingp(meta)) break;
		if (meta->timestamp)
		{
			mapping ts=(persist["window/timestamp_local"]?localtime:gmtime)(meta->timestamp);
			txt+="  "+strftime(persist["window/timestamp"]||default_ts_fmt,ts);
		}
		//Add further meta-information display here
	}; //Ignore errors
	//TODO: Cache the text, if performance is an issue. Be sure to flush the cache when appropriate.
	setstatus(txt);
	if (subw->mouse_down && (line!=subw->selendline || col!=subw->selendcol))
	{
		subw->mouse_down=2; //Mouse has moved.
		highlight(subw,subw->selstartline,subw->selstartcol,line,col);
	}
}

/**
 * Add a line of output (anything other than a prompt)
 * If msg is an array, it is assumed to be alternating colors and text.
 * Otherwise, additional arguments will be processed with sprintf().
 */
void say(mapping|void subw,string|array msg,mixed ... args)
{
	if (!subw) subw=current_subw();
	if (stringp(msg))
	{
		if (sizeof(args)) msg=sprintf(msg,@args);
		if (msg[-1]=='\n') msg=msg[..<1];
		foreach (msg/"\n",string line) say(subw,({colors[7],line}));
		return;
	}
	for (int i=0;i<sizeof(msg);i+=2) if (!msg[i]) msg[i]=colors[7];
	if (!mappingp(msg[0])) msg=({([])})+msg;
	msg[0]->timestamp=time(1);
	if (subw->logfile) subw->logfile->write(string_to_utf8(filter(msg,stringp)*""+"\n"));
	array lines=({ });
	//Wrap msg into lines, making at least one entry. Note that, in current implementation,
	//it'll wrap at any color change as if it were a space. This is unideal, but it
	//simplifies the code a bit.
	int wrap=persist["window/wrap"]; string wrapindent=persist["window/wrapindent"]||"";
	int pos=0;
	if (wrap) for (int i=2;i<sizeof(msg);i+=2)
	{
		int end=pos+sizeof(msg[i]);
		if (end<=wrap) {pos=end; continue;}
		array cur=msg[..i];
		string part=msg[i];
		end=wrap-pos;
		if (sizeof(part)>end)
		{
			int wrappos=end;
			while (wrappos && part[wrappos]!=' ') --wrappos;
			//If there are no spaces, break at the color change (if there's text before it), or just break where there's no space.
			//Note that this will refuse to break at or within the wrapindent, on subsequent lines.
			if ((!wrappos || (sizeof(lines) && wrappos<=sizeof(wrapindent))) && !pos) wrappos=wrap;
			cur[-1]=part[..wrappos-1];
			msg=({msg[0]+([]),msg[i-1],wrapindent+String.trim_all_whites(part[wrappos..])})+msg[i+1..];
		}
		lines+=({cur});
		i=pos=0;
	}
	subw->lines+=lines+({msg});
	subw->activity=1;
	switch (persist["notif/activity"])
	{
		case 1: if (subw!=current_subw()) break; //Play with fall-through. If the config option is 2, present the window regardless of current_page; if it's one, present only if current page; otherwise, don't present.
		case 2: if (!paused) mainwindow->present(); //Present the window only if we're not paused.
	}
	redraw(subw);
}

/**
 * Connect to a world
 */
void connect(mapping info,mapping|void subw)
{
	if (!subw) subw=current_subw();
	if (!info)
	{
		//Disconnect
		if (!subw->connection || !subw->connection->sock) return; //Silent if nothing to dc
		subw->connection->sock->close(); G->G->connection->sockclosed(subw->connection);
		return;
	}
	if (subw->connection && subw->connection->sock) {say(subw,"%% Already connected."); return;}
	subw->connection=G->G->connection->connect(subw,info);
	subw->tabtext=info->tabtext || info->name || "(unnamed)";
}

/**
 *
 */
void redraw(mapping subw)
{
	int height=(int)subw->scr->get_property("page size")+subw->lineheight*(sizeof(subw->lines)+1);
	if (height!=subw->totheight) subw->display->set_size_request(-1,subw->totheight=height);
	if (subw==current_subw()) subw->activity=0;
	notebook->set_tab_label_text(subw->page,"* "*subw->activity+subw->tabtext);
	subw->maindisplay->queue_draw();
}

object mkcolor(int fg,int bg)
{
	return colors[fg];
}

//Paint one piece of text at (x,y), returns the x for the next text.
/**
 *
 */
int painttext(GTK2.DrawingArea display,GTK2.GdkGC gc,int x,int y,string txt,GTK2.GdkColor fg,GTK2.GdkColor bg)
{
	if (txt=="") return x;
	object layout=display->create_pango_layout(txt);
	mapping sz=layout->index_to_pos(sizeof(txt)-1);
	if (bg!=colors[0]) //Why can't I just set_background and then tell draw_text to cover any background pixels? Meh.
	{
		gc->set_foreground(bg); //(sic)
		display->draw_rectangle(gc,1,x,y,(sz->x+sz->width)/1024,sz->height/1024);
	}
	gc->set_foreground(fg);
	display->draw_text(gc,x,y,txt);
	destruct(layout);
	return x+(sz->x+sz->width)/1024;
}

//Paint one line of text at the given 'y'. Will highlight from hlstart to hlend with inverted fg/bg colors.
/**
 *
 */
void paintline(GTK2.DrawingArea display,GTK2.GdkGC gc,array(mapping|GTK2.GdkColor|string) line,int y,int hlstart,int hlend)
{
	int x=3;
	for (int i=mappingp(line[0]);i<sizeof(line);i+=2) if (sizeof(line[i+1]))
	{
		string txt=replace(line[i+1],"\n","\\n");
		if (hlend<0) hlstart=sizeof(txt); //No highlight left to do.
		if (hlstart>0)
		{
			//Draw the leading unhighlighted part (which might be the whole string).
			x=painttext(display,gc,x,y,txt[..hlstart-1],line[i] || colors[7],colors[0]);
		}
		if (hlstart<sizeof(txt))
		{
			//Draw the highlighted part (which might be the whole string).
			x=painttext(display,gc,x,y,txt[hlstart..min(hlend,sizeof(txt))],colors[0],line[i] || colors[7]);
			if (hlend<sizeof(txt))
			{
				//Draw the trailing unhighlighted part.
				x=painttext(display,gc,x,y,txt[hlend+1..],line[i] || colors[7],colors[0]);
			}
		}
		hlstart-=sizeof(txt); hlend-=sizeof(txt);
	}
}

/**
 *
 */
int paint(object self,object ev,mapping subw)
{
	int start=ev->y-subw->lineheight,end=ev->y+ev->height+subw->lineheight; //We'll paint complete lines, but only those lines that need painting.
	GTK2.DrawingArea display=subw->display; //Cache, we'll use it a lot
	display->set_background(colors[0]);
	GTK2.GdkGC gc=GTK2.GdkGC(display);
	int y=(int)subw->scr->get_property("page size");
	int ssl=subw->selstartline,ssc=subw->selstartcol,sel=subw->selendline,sec=subw->selendcol;
	if (zero_type(ssl)) ssl=sel=-1;
	else if (ssl>sel || (ssl==sel && ssc>sec)) [ssl,ssc,sel,sec]=({sel,sec,ssl,ssc}); //Get the numbers forward rather than backward
	int endl=min((end-y)/subw->lineheight,sizeof(subw->lines));
	for (int l=max(0,(start-y)/subw->lineheight);l<=endl;++l)
	{
		array(mapping|GTK2.GdkColor|string) line=(l==sizeof(subw->lines)?subw->prompt:subw->lines[l]);
		int hlstart=-1,hlend=-1;
		if (l>=ssl && l<=sel)
		{
			if (l==ssl) hlstart=ssc;
			if (l==sel) hlend=sec-1; else hlend=1<<30;
		}
		paintline(display,gc,line,y+l*subw->lineheight,hlstart,hlend);
	}
}

/**
 *
 */
void settext(mapping subw,string text)
{
	subw->ef->set_text(text);
	subw->ef->set_position(sizeof(text));
}

/**
 *
 */
int keypress(object self,array|object ev,mapping subw)
{
	if (arrayp(ev)) ev=ev[0];
	switch (ev->keyval)
	{
		case 0xFF0D: case 0xFF8D: enterpressed(subw); return 1; //Enter (works only when COMPAT_SIGNAL not needed)
		case 0xFF52: //Up arrow
		{
			if (subw->histpos==-1) subw->histpos=sizeof(subw->cmdhist);
			else if (!subw->histpos) return 1;
			int pos = (ev->state&GTK2.GDK_CONTROL_MASK) && subw->ef->get_position();
			string pfx = subw->ef->get_text()[..pos-1];
			int hp=subw->histpos;
			while (hp && !has_prefix(subw->cmdhist[--hp],pfx));
			if (has_prefix(subw->cmdhist[hp],pfx)) settext(subw,subw->cmdhist[subw->histpos=hp]);
			if (ev->state&GTK2.GDK_CONTROL_MASK) subw->ef->set_position(pos);
			return 1;
		}
		case 0xFF54: //Down arrow
		{
			if (subw->histpos==-1)
			{
				//Optionally clear the EF
				return 1;
			}
			int pos = (ev->state&GTK2.GDK_CONTROL_MASK) && subw->ef->get_position();
			string pfx = subw->ef->get_text()[..pos-1];
			int hp=subw->histpos;
			while (++hp<sizeof(subw->cmdhist) && !has_prefix(subw->cmdhist[hp],pfx));
			if (hp<sizeof(subw->cmdhist)) settext(subw,subw->cmdhist[subw->histpos=hp]);
			else {subw->ef->set_text(pfx); subw->histpos=-1;}
			if (ev->state&GTK2.GDK_CONTROL_MASK) subw->ef->set_position(pos);
			return 1;
		}
		case 0xFF1B: //Esc
			if (has_index(subw,"selstartline")) {highlight(subw,-1,0,0,0); subw->mouse_down=0;}
			else subw->ef->set_text(""); //Clear EF if there's nothing to unhighlight
			return 1;
		case 0xFF09: case 0xFE20: //Tab and shift-tab
		{
			if (ev->state&GTK2.GDK_CONTROL_MASK)
			{
				//Note: Not using notebook->{next|prev}_page() as they don't cycle.
				int page=notebook->get_current_page();
				if (ev->state&GTK2.GDK_SHIFT_MASK) {if (--page<0) page=notebook->get_n_pages()-1;}
				else {if (++page>=notebook->get_n_pages()) page=0;}
				notebook->set_current_page(page);
				return 1;
			}
			subw->ef->set_position(subw->ef->insert_text("\t",1,subw->ef->get_position()));
			return 1;
		}
		case 0xFF55: //PgUp
		{
			if (ev->state&GTK2.GDK_CONTROL_MASK)
			{
				//TODO: Scroll up to last activity
				return 1;
			}
			object scr=subw->scr; scr->set_value(scr->get_value()-scr->get_property("page size"));
			return 1;
		}
		case 0xFF56: //PgDn
		{
			object scr=subw->scr;
			float pg=scr->get_property("page size");
			if (ev->state&GTK2.GDK_CONTROL_MASK)
			{
				//Snap down to the bottom and unpause.
				scr->set_value(scr->get_property("upper")-pg);
				paused=0;
				statustxt->paused->set_text("");
				return 1;
			}
			scr->set_value(min(scr->get_value()+pg,scr->get_property("upper")-pg));
			return 1;
		}
		case 0xFF13: //Pause (GTK official value (GDK_KEY_Pause); Linux produces this)
		case 0xFFFFFF: //GDK_KEY_VoidSymbol; Windows produces this instead of FF13, for some reason
		{
			paused=!paused;
			statustxt->paused->set_text("<PAUSED>"*paused);
			return 1;
		}
		#if constant(DEBUG)
		case 0xFFE1: case 0xFFE2: //Shift
		case 0xFFE3: case 0xFFE4: //Ctrl
		case 0xFFE7: case 0xFFE8: //Windows keys
		case 0xFFE9: case 0xFFEA: //Alt
			break;
		default: say(subw,"%%%% keypress: %X",ev->keyval); break;
		#endif
	}
	if (mapping numpad=numpadnav[sprintf("%x",ev->keyval)])
	{
		string cmd=numpad->cmd;
		if (!numpadspecial[cmd] && !has_prefix(cmd,"go ")) cmd="go "+cmd;
		send(subw->connection,cmd+"\r\n");
		return 1;
	}
}

/**
 *
 */
int enterpressed(mapping subw,string|void cmd)
{
	//TODO: Figure out what the return value is supposed to mean.
	//It's used only in COMPAT_SIGNAL mode, and it seems a little inconsistent.
	//I think this probably ought to just return void.
	if (!cmd) {cmd=subw->ef->get_text(); subw->ef->set_text("");}
	subw->histpos=-1;
	subw->prompt[0]->timestamp=time(1);
	if (!subw->passwordmode)
	{
		if (cmd!="" && (!sizeof(subw->cmdhist) || cmd!=subw->cmdhist[-1])) subw->cmdhist+=({cmd});
		say(subw,subw->prompt+({colors[6],cmd}));
	}
	else subw->lines+=({subw->prompt});
	subw->prompt[0]=([]); //Reset the info mapping (which gets timestamp and such) but keep the prompt itself for the moment
	if (sizeof(cmd)>1 && cmd[0]=='/' && cmd[1]!='/')
	{
		redraw(subw);
		sscanf(cmd,"/%[^ ] %s",cmd,string args);
		if (G->G->commands[cmd] && G->G->commands[cmd](args||"",subw)) return 0;
		say(subw,"%% Unknown command.");
		return 0;
	}
	execcommand(subw,cmd,0);
	return 1;
}

/**
 * Execute a command, passing it via hooks
 * If skiphook is nonzero, will skip all hooks up to and including that name.
 * If the subw is in password mode, hooks will not be called at all.
 */
void execcommand(mapping subw,string cmd,string|void skiphook)
{
	if (!subw->passwordmode)
	{
		array names=indices(G->G->hooks),hooks=values(G->G->hooks); sort(names,hooks); //Sort by name for consistency
		for (int i=0;i<sizeof(hooks);++i) if (!skiphook || skiphook<names[i])
			if (mixed ex=catch {if (hooks[i]->inputhook(cmd,subw)) {redraw(subw); return;}}) say(subw,"Error in input hook: "+describe_backtrace(ex));
	}
	subw->prompt=({([])}); redraw(subw);
	send(subw->connection,cmd+"\r\n");
}

/**
 * Engage/disengage password mode
 */
void   password(mapping subw) {subw->passwordmode=1; subw->ef->set_visibility(0);}
void unpassword(mapping subw) {subw->passwordmode=0; subw->ef->set_visibility(1);}

/**
 * Retrieve the specified (or current) subw's reconnection string
 */
string recon(mapping|void subw) {return ((subw||current_subw())->connection||([]))->recon;}

/**
 *
 */
void addtab() {subwindow("New tab");}

/**
 * Actually close a tab - that is, assume the user has confirmed the closing or doesn't need to
 */
void real_closetab(int removeme)
{
	if (sizeof(tabs)<2) addtab();
	tabs[removeme]->signals=0; connect(0,tabs[removeme]);
	tabs=tabs[..removeme-1]+tabs[removeme+1..];
	notebook->remove_page(removeme);
	if (!sizeof(tabs)) addtab();
}

void closetab_response(object self,int response,int removeme)
{
	self->destroy();
	if (response==GTK2.RESPONSE_OK) real_closetab(removeme);
}

/**
 * First-try at closing a tab. May call real_closetab() or raise a prompt.
 */
void closetab()
{
	int removeme=notebook->get_current_page();
	if (!tabs[removeme]->connection || !tabs[removeme]->connection->sock) {real_closetab(removeme); return;} //TODO: Use ?->sock for this
	GTK2.MessageDialog(0,GTK2.MESSAGE_WARNING,GTK2.BUTTONS_OK_CANCEL,"You have an active connection, really close this tab?")
		->show()
		->signal_connect("response",closetab_response,removeme);
}

class advoptions
{
	inherit configdlg;
	mapping(string:mapping(string:mixed)) items=([
		//TODO: Have a "type":"boolean" for flags, or maybe a "type":({"option","other option"}) to make a drop-down.
		"Activity alert":(["path":"notif/activity","type":"int","default":0,"desc":"The Gypsum window can be 'presented' to the user in a platform-specific way. Should this happen:\n\n0: Never\n1: When there's activity in the currently-active tab\n2: When there's activity in any tab?"]),
		"Beep":(["path":"notif/beep","type":"int","default":0,"desc":"When the server requests a beep, what should be done?\n\n0: Try both the following, in order\n1: Call on an external 'beep' program\n2: Use the GTK2 beep() action\n99: Suppress the beep entirely"]),
		"Keep-Alive":(["path":"ka/delay","default":240,"desc":"Number of seconds between keep-alive messages. Set this to a little bit less than your network's timeout. Note that this should not reset the server's view of idleness and does not violate the rules of Threshold RPG.","type":"int"]),
		"Timestamp":(["path":"window/timestamp","default":default_ts_fmt,"desc":"Display format for line timestamps as shown when the mouse is hovered over them. Uses strftime markers. TODO: Document this better."]),
		"Timestamp localtime":(["path":"window/timestamp_local","default":0,"desc":"Display line timestamps in local time (1) rather than in UTC (0).","type":"int"]),
		"Wrap":(["path":"window/wrap","default":0,"desc":"Wrap text to the specified width (in characters). 0 to disable.","type":"int"]),
		"Wrap indent":(["path":"window/wrapindent","default":"","desc":"Indent/prefix wrapped text with the specified text - a number of spaces works well."]),
		#define COMPAT(x) "\n\n0: Autodetect\n1: Force compatibility mode\n2: Disable compatibility mode"+(has_index(all_constants(),"COMPAT_"+upper_case(x))?"\n\nCurrently active.":"\n\nCurrently inactive."),"type":"int","default":0,"path":"compat/"+x
		"Compat: Scroll":(["desc":"Some platforms have display issues with having more than about 2000 lines of text. The fix is a slightly ugly 'flicker' of the scroll bar. Requires restart."COMPAT("scroll")]),
		"Compat: Events":(["desc":"Older versions of Pike cannot do 'before' events. The fix involves simulating them in various ways, with varying levels of success. Requires restart."COMPAT("signal")])
	]);
	constant allow_new=0;
	constant allow_rename=0;
	constant allow_delete=0;
	mapping(string:mixed) windowprops=(["title":"Advanced Options"]);
	void create() {::create("advoptions");}

	GTK2.Widget make_content()
	{
		return GTK2.Vbox(0,10)
			->pack_start(win->kwd=GTK2.Label((["yalign":1.0])),0,0,0)
			->pack_start(win->value=GTK2.Entry(),0,0,0)
			->pack_end(win->desc=GTK2.Label((["xalign":0.0,"yalign":0.0]))->set_size_request(300,150)->set_line_wrap(1),1,1,0)
		;
	}

	void save_content(mapping(string:mixed) info)
	{
		mixed value=win->value->get_text();
		if (info->type=="int") value=(int)value;
		persist[info->path]=value;
	}

	void load_content(mapping(string:mixed) info)
	{
		win->value->set_text((string)(persist[info->path] || info->default));
		win->desc->set_text(info->desc);
	}
}

class channelsdlg
{
	inherit configdlg;
	mapping(string:mapping(string:mixed)) items=channels;
	mapping(string:mixed) windowprops=(["title":"Channel colors"]);
	void create() {::create("channelsdlg");}

	GTK2.Widget make_content()
	{
		return two_column(({
			"Channel name",win->kwd=GTK2.Entry(),
			"Color (0-255)",GTK2.Hbox(0,10)
				->add(GTK2.Label("Red"))
				->add(win->r=GTK2.Entry()->set_size_request(40,-1))
				->add(GTK2.Label("Green"))
				->add(win->g=GTK2.Entry()->set_size_request(40,-1))
				->add(GTK2.Label("Blue"))
				->add(win->b=GTK2.Entry()->set_size_request(40,-1))
		}));
	}

	void save_content(mapping(string:mixed) info)
	{
		foreach (({"r","g","b"}),string c) info[c]=(int)win[c]->get_text();
		persist["color/channels"]=channels;
	}

	void load_content(mapping(string:mixed) info)
	{
		if (zero_type(info["r"])) info->r=info->g=info->b=255;
		foreach (({"r","g","b"}),string c) win[c]->set_text((string)info[c]);
	}
}

class fontdlg
{
	inherit configdlg;
	mapping(string:mapping(string:mixed)) items=fonts;
	constant allow_new=0;
	void create() {::create("fontdlg");}

	GTK2.Widget make_content()
	{
		win->list->set_enable_search(0); //Disable the type-ahead search, which is pretty useless when there are this few items
		return GTK2.Vbox(0,0)
			->add(win->kwd=GTK2.Label((["label":"Section","xalign":0.5])))
			->add(win->fontsel=GTK2.FontSelection())
		;
	}

	void save_content(mapping(string:mixed) info)
	{
		string name=win->fontsel->get_font_name();
		if (info->name==name) return; //No change, no need to dump the cached object
		info->name=name;
		m_delete(fontdesc,name);
		persist["window/font"]=fonts;
		setfonts(tabs[*]);
		redraw(tabs[*]);
		tabs->display->set_background(colors[0]); //For some reason, failing to do this results in the background color flipping to grey when fonts are changed. Weird.
	}

	void load_content(mapping(string:mixed) info)
	{
		if (info->name) win->fontsel->set_font_name(info->name);
	}
}

class keyboard
{
	inherit configdlg;
	mapping(string:mapping(string:mixed)) items=numpadnav;
	mapping(string:mixed) windowprops=(["title":"Numeric keypad navigation"]);
	void create() {::create("keyboard");}

	GTK2.Widget make_content()
	{
		return two_column(({
			"Key (hex code)",win->kwd=GTK2.Entry(),
			"Press key here ->",win->key=GTK2.Entry(),
			"Command",win->cmd=GTK2.Entry(),
		}));
	}

	void makewindow()
	{
		::makewindow();
		//Add a button to the bottom row
		win->buttonbox->add(win->pb_std=GTK2.Button((["label":"Standard","use-underline":1])));
	}

	int keypress(object self,array|object ev)
	{
		if (arrayp(ev)) ev=ev[0];
		switch (ev->keyval) //Let some keys through untouched
		{
			case 0xFFE1..0xFFEE: //Modifier keys
			case 0xFF09: case 0xFE20: //Tab/shift-tab
				return 0;
		}
		win->kwd->set_text(sprintf("%x",ev->keyval));
		return 1;
	}

	void stdkeys_response(object self,int response)
	{
		self->destroy();
		if (response!=GTK2.RESPONSE_OK) return;
		object store=win->list->get_model();
		foreach (({"look","southwest","south","southeast","west","glance","east","northwest","north","northeast"});int i;string cmd)
		{
			if (!numpadnav["ffb"+i])
			{
				numpadnav["ffb"+i]=(["cmd":cmd]);
				store->set_value(store->append(),0,"ffb"+i);
			}
			else numpadnav["ffb"+i]->cmd=cmd;
		}
		persist["window/numpadnav"]=numpadnav;
		selchanged();
	}

	void pb_std()
	{
		GTK2.MessageDialog(0,GTK2.MESSAGE_WARNING,GTK2.BUTTONS_OK_CANCEL,"Adding/updating standard nav keys will overwrite anything you currently have on those keys. Really do it?")
			->show()
			->signal_connect("response",stdkeys_response);
	}

	void dosignals()
	{
		::dosignals();
		win->signals+=({
			#if constant(COMPAT_SIGNAL)
			gtksignal(win->key,"key_press_event",keypress),
			#else
			gtksignal(win->key,"key_press_event",keypress,0,UNDEFINED,1),
			#endif
			gtksignal(win->pb_std,"clicked",pb_std),
		});
	}

	void save_content(mapping(string:mixed) info)
	{
		info->cmd=win->cmd->get_text();
		persist["window/numpadnav"]=numpadnav;
	}

	void load_content(mapping(string:mixed) info)
	{
		win->cmd->set_text(info->cmd||"");
	}
}

class aboutdlg
{
	inherit window;
	void create() {::create("help/about");}

	void makewindow()
	{
		string ver=gypsum_version();
		if (ver!=INIT_GYPSUM_VERSION) ver=sprintf("%s (upgraded from %s)",ver,INIT_GYPSUM_VERSION);
		win->mainwindow=GTK2.Window((["title":"About Gypsum","transient-for":G->G->window->mainwindow]))->add(GTK2.Vbox(0,0)
			->add(GTK2.Label(#"Pike MUD client for Windows/Linux/Mac (and others)

Free software - see README for license terms

By Chris Angelico, rosuav@gmail.com

Version "+ver+", as far as can be ascertained :)"))
			->add(GTK2.HbuttonBox()->add(win->pb_close=GTK2.Button((["use-stock":1,"label":GTK2.STOCK_CLOSE]))))
		);
		::makewindow();
	}

	void dosignals()
	{
		::dosignals();
		win->signals+=({
			gtksignal(win->pb_close,"clicked",lambda() {win->mainwindow->destroy();}),
		});
	}
}

/**
 *
 */
void colorcheck(object self,mapping subw)
{
	array(int) col=({255,255,255});
	if (mapping c=channels[(self->get_text()/" ")[0]]) col=({c->r,c->g,c->b});
	if (equal(subw->cur_fg,col)) return;
	subw->cur_fg=col;
	self->modify_base(GTK2.STATE_NORMAL,GTK2.GdkColor(0,0,0));
	self->modify_text(GTK2.STATE_NORMAL,GTK2.GdkColor(@col));
}

//Anything that calls this function is by definition a TODO, though this itself isn't.
void TODO()
{
	say(0,"%% Sorry, that function isn't implemented yet.");
}

/**
 *
 */
void create(string name)
{
	if (!G->G->window)
	{
		add_gypsum_constant("say",bouncer("window","say")); //Say, Bouncer, say!
		GTK2.setup_gtk();
		colors=({});
		foreach (defcolors/" ",string col) colors+=({GTK2.GdkColor(@reverse(array_sscanf(col,"%2x%2x%2x")))});
		mainwindow=GTK2.Window(GTK2.WindowToplevel);
		mainwindow->set_title("Gypsum");
		if (array pos=persist["window/winpos"])
		{
			pos+=({800,600}); mainwindow->set_default_size(pos[2],pos[3]);
			mainwindow->move(pos[0],pos[1]);
		}
		else mainwindow->set_default_size(800,500);
		GTK2.AccelGroup accel=G->G->accel=GTK2.AccelGroup();
		G->G->plugin_menu=([]);
		mainwindow->add_accel_group(accel)->add(GTK2.Vbox(0,0)
			->pack_start(GTK2.MenuBar()
				->add(GTK2.MenuItem("_File")->set_submenu(GTK2.Menu()
					->add(menuitem("_New Tab","addtab")->add_accelerator("activate",accel,'t',GTK2.GDK_CONTROL_MASK,GTK2.ACCEL_VISIBLE))
					->add(menuitem("Close tab","closetab")->add_accelerator("activate",accel,'w',GTK2.GDK_CONTROL_MASK,GTK2.ACCEL_VISIBLE))
					->add(menuitem("_Connect","connect_menu"))
					->add(menuitem("_Disconnect","disconnect_menu"))
					->add(menuitem("E_xit","window_close"))
				))
				->add(GTK2.MenuItem("_Options")->set_submenu(GTK2.Menu()
					->add(menuitem("_Font","fontdlg"))
					->add(menuitem("_Colors","channelsdlg"))
					->add(menuitem("_Keyboard","keyboard"))
					->add(menuitem("Ad_vanced options","advoptions"))
					#if constant(COMPAT_SIGNAL)
					->add(menuitem("Save all window positions","savewinpos"))
					#endif
				))
				->add(GTK2.MenuItem("_Plugins")->set_submenu(G->G->plugin_menu[0]=GTK2.Menu()
					->add(menuitem("_Configure","configure_plugins"))
					->add(GTK2.SeparatorMenuItem())
				))
				->add(GTK2.MenuItem("_Help")->set_submenu(GTK2.Menu()
					->add(menuitem("_About","aboutdlg"))
				))
			,0,0,0)
			->add(notebook=GTK2.Notebook())
			->pack_end(statusbar=GTK2.Hbox(0,0),0,0,0)
			#if constant(COMPAT_SIGNAL)
			->pack_end(defbutton=GTK2.Button()->set_size_request(0,0)->set_flags(GTK2.CAN_DEFAULT),0,0,0)
			#endif
		)->show_all();
		#if constant(COMPAT_SIGNAL)
		defbutton->grab_default();
		#endif
		addtab();
		call_out(mainwindow->present,0); //After any plugin windows have loaded, grab - or attempt to grab - focus back to the main window.
	}
	else
	{
		object other=G->G->window;
		colors=other->colors; notebook=other->notebook; mainwindow=other->mainwindow;
		#if constant(COMPAT_SIGNAL)
		defbutton=other->defbutton;
		#endif
		tabs=other->tabs; statusbar=other->statusbar;
		if (other->signals) other->signals=0; //Clear them out, just in case.
		if (other->menu) menu=other->menu;
		foreach (tabs,mapping subw) subwsignals(subw);
	}
	G->G->window=this;
	::create(name);
	mainwsignals();
}

/**
 *
 */
int window_destroy() {exit(0);}

void closewindow_response(object self,int response)
{
	self->destroy();
	if (response==GTK2.RESPONSE_OK) exit(0);
}

int window_close()
{
	int conns=sizeof((tabs->connection-({0}))->sock-({0})); //Number of active connections
	if (!conns) {exit(0); return 1;}
	GTK2.MessageDialog(0,GTK2.MESSAGE_WARNING,GTK2.BUTTONS_OK_CANCEL,"You have "+conns+" active connection(s), really quit?")
		->show()
		->signal_connect("response",closewindow_response);
	return 1;
}

//Either reconnect, or give the world list.
/**
 *
 */
void connect_menu(object self)
{
	G->G->commands->connect("dlg",current_subw());
}

/**
 *
 */
void disconnect_menu(object self) {connect(0);}

/**
 * Create a menu item and retain it for subsequent signal binding in mainwsignals()
 */
GTK2.MenuItem menuitem(mixed content,string func)
{
	GTK2.MenuItem ret=GTK2.MenuItem(content);
	menu[ret]=func;
	return ret;
}

int showev(object self,array ev,int dummy) {werror("%O->%O\n",self,(mapping)ev[0]);}

/**
 * COMPAT_SIGNAL bouncer
 */
int enterpressed_glo(object self)
{
	object focus=mainwindow->get_focus();
	object parent=focus->get_parent();
	while (parent->get_name()!="GtkNotebook") parent=(focus=parent)->get_parent();
	return enterpressed(tabs[parent->page_num(focus)]);
}

/**
 * COMPAT_SIGNAL window position saver hack
 */
void savewinpos()
{
	object ev=class {string type="configure";}();
	configevent(mainwindow,ev);
	foreach (G->G->windows;string name;mapping win) if (win->save_position_hook) win->save_position_hook(win->mainwindow,ev);
}

/**
 *
 */
int switchpage(object|mapping subw)
{
	if (objectp(subw)) {call_out(switchpage,0,current_subw()); return 0;} //Let the signal handler return before actually doing stuff
	subw->activity=0; notebook->set_tab_label_text(subw->page,subw->tabtext);
	if (subw==current_subw()) subw->ef->grab_focus();
}

mapping(string:int) pos;
void configevent(object self,object ev)
{
	#if constant(COMPAT_SIGNAL)
	if (ev->type!="configure") return; //This check isn't needed if we can hook configure_event
	#endif
	if (!pos) call_out(savepos,0.1); //Save a moment after the window moves. "Sweep" movement creates a spew of these events, don't keep saving.
	pos=self->get_position(); //Will return x and y
}

void savepos()
{
	mapping sz=mainwindow->get_size();
	persist["window/winpos"]=({pos->x,pos->y,sz->width,sz->height});
	pos=0;
}

void mainwsignals()
{
	signals=({
		gtksignal(mainwindow,"destroy",window_destroy),
		gtksignal(mainwindow,"delete_event",window_close),
		gtksignal(notebook,"switch_page",switchpage),
		#if constant(COMPAT_SIGNAL)
		gtksignal(defbutton,"clicked",enterpressed_glo),
		//gtksignal(mainwindow,"event",configevent), //See equiv in globals.pike
		#else
		gtksignal(mainwindow,"configure_event",configevent,0,UNDEFINED,1),
		#endif
	});
	foreach (menu;GTK2.MenuItem widget;string func)
		signals+=({gtksignal(widget,"activate",this[func] || TODO)}); //If the function can't be found, put it through to TODO(). This is not itself a TODO.
}
