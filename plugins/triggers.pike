//By popular request: Triggers.
//At its core, a trigger is a request that, whenever something comes from the
//server, an action be performed. That action could be to play a sound,
//set or clear some internal state (messing with anything Gypsum itself
//cares about would be unsupported, of course), send a string back to the
//server, or anything else.

inherit hook;
inherit plugin_menu;

constant plugin_active_by_default = 1;

constant docstring=#"
Triggers let you perform some action whenever a specified message comes
from the server. The action can be incredibly flexible.
";

//Leaving room for a future triggers/worldname
mapping(string:mapping(string:mixed)) triggers = persist->setdefault("triggers/global", ([]));

int output(mapping(string:mixed) subw,string line)
{
	foreach (triggers;;mapping tr)
	{
		switch (tr->match)
		{
			case "Substring": if (!has_value(line, tr->text)) continue; break;
			case "Entire": if (line != tr->text) continue; break;
			case "Prefix": if (!has_prefix(line, tr->text)) continue; break;
			default: continue;
		}
		//If we get here, the trigger matches. Do the actions.
		if (tr->message != "") say(subw, "%% "+tr->message);
		if (tr->sound != "") play_sound(tr->sound);
		if (tr->invoke != "") invoke_browser(tr->invoke);
		if (tr->response != "") send(subw, tr->response+"\r\n"); //Not officially supported by core - may have to change later.
		if (tr->counter != "") G->G["counter_" + tr->counter]++; //On par with HQ9++, there's no way to actually do anything with this.
		if (tr->present) G->G->window->mainwindow->present();
		if (tr->beep) beep(1); //No point parameterizing this - the underlying beep call currently ignores its arg anyway.
		if (tr->fgcol || tr->bgcol)
		{
			//HACK - reaches into internals.
			//TODO: Handle "unspecified" as distinct from "black"
			subw->connection->curmsg[1] = G->G->window->mkcolor(tr->fgcol, tr->bgcol);
		}
	}
}

constant menu_label = "Triggers";
class menu_clicked
{
	inherit configdlg;
	constant persist_key = "triggers/global";
	constant elements = ({
		"kwd:Name/mnemonic", "text:Trigger text",
		"@Match style=Substring", ({"Substring", "Entire", "Prefix"}), //And maybe regex and others, as needed
		"'Actions - leave blank if not applicable:",
		"sound:Play sound file",
		"invoke:Open file or URL",
		"message:Display message locally",
		"response:Send command to server",
		"?Present (grab focus)",
		"?Beep",
		"counter:Increment counter [keyword]", //Experimental
		"'counterstatus:",
		"#fgcol:Foreground color",
		"#bgcol:Background color",
	});

	void load_content(mapping(string:mixed) info)
	{
		int val = G->G["counter_" + info->counter]; //Yes, even if it's 0 or "". They'll just be zero themselves.
		win->counterstatus->set_text(val ? (string)val : "");
	}
}

void create(string name) {::create(name);}
