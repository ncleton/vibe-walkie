"""A real GTK text editor used only as an integration-test target."""
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

window = Gtk.Window(title="Vibe Walkie integration editor")
window.set_default_size(640, 480)
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
entry = Gtk.Entry()
entry.set_text("Initial ")
entry.get_accessible().set_name("Integration text")
secret = Gtk.Entry()
secret.set_visibility(False)
secret.get_accessible().set_name("Password")
box.pack_start(entry, False, False, 0)
box.pack_start(secret, False, False, 0)
window.add(box)
window.connect("destroy", Gtk.main_quit)
window.show_all()
entry.grab_focus()
entry.set_position(-1)
Gtk.main()
