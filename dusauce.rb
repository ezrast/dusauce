#!/usr/bin/env ruby
# du output analyzer
# by Ezra Stevens

require 'optparse'

$abs_threshold = 0
$rel_threshold = 0.0002

OptionParser.new do |opts|
  opts.banner = 'Usage: dusauce.rb [OPTIONS] FILE'
  
  opts.on('-tTHRESH', '--threshold=THRESH', Integer, 'Only parse nodes greater than THRESH kB') do |tt|
    $abs_threshold = tt
  end

  opts.on('-TTHRES', '--relative-threshold=THRESH', Float, 'Only parse nodes greater than THRESH times the total volume size; defaults to ' + $rel_threshold.to_s) do |tt|
    $rel_threshold = tt
  end

  opts.on('-h', '--help', 'Prints this message') do
    puts opts
    exit
  end
  
  opts.banner 
  
  $opts = opts
end.parse!

unless(ARGV.length == 1)
  puts $opts
  exit
end
$inputFile = ARGV.shift

# Format numbers nicely
class Integer
  def to_s_commas
    return to_s.reverse.gsub(/...(?=.)/,'\&,').reverse
  end

  def to_s_filesize
    ret = self.to_f
    %w(kiB MiB GiB TiB PiB EiB ZiB).each { |ww|
      return ('%.1f' % ret) + " #{ww}" if ret < 1024.0
      ret /= 1024.0
    }
    return ('%.1f' % ret) + " YiB"
  end

  alias_method :to_sf, :to_s_commas
end

# A file or folder - basically contains the info from a single line of du output
class Node
  
  attr_reader :name, :children, :parent, :size, :depth
  attr_accessor :open
  
  def initialize(name,parent,size)
    @name = name
    @parent = parent
    @size = size
    @children = Array.new
    @open = false
    
    if @parent
      @parent.addChild(self)
      @depth = @parent.depth+1
    else
      @depth = 0
    end
      
  end
  
  def addChild(child)
    @children.unshift(child)
    return child
  end
  
  def fullName
    return parent.fullName + @name if parent
    return name
  end

  def to_s(sizeColumnWidth = 0)
    ' '*@depth + @size.to_sf.rjust(sizeColumnWidth) + '   ' + (@children.empty? ? ' | ' : (@open ? ' \\ ' : ' + ')) + (@name[0] == '/' ? @name[1..-1] : @name) + (@children.empty? ? '' : '/')
  end
  

  def list(sort = nil, sortReverse = false, threshold = 0, arr = nil)
    if(sort)
      @children.sort_by!{|obj| obj.send(sort)}
      @children.reverse! if (sortReverse)
    end
    
    arr = Array.new unless arr
    arr.push(self)
    
    if(@open)
      @children.each do |child|
        child.list(sort, sortReverse, threshold, arr) unless child.size < threshold
      end
    end
    
    return arr
  end
  
end

# let's get to parsing
print 'Reading ' + $inputFile + '...'
lines = File.open($inputFile) {|file| file.readlines}
print ' ' + lines.length.to_s + " lines read.\n"
#sometimes foreign characters make regexps sad. There's probably a proper way to handle that
#but character encodings are scary so I'll just destroy anything that isn't ASCII.
lines.map! {|ll| ll.encode(Encoding::UTF_8, 'binary', :invalid => :replace, :undef => :replace)}

unless lines.empty?
  rootLine = lines.pop
  #don't include the trailing slash in the root node name, if present. It's okay for the root node name to be "".
  raise('Format Error: '+rootLine) unless rootLine =~ /^([0-9]+)\s+(.*?)\/?$/
  currentNode = $rootNode = Node.new($2.strip,nil,$1.to_i)

  $threshold = [($rel_threshold * $1.to_i).to_i, $abs_threshold].max
  
  count = 0
  step = [lines.length / 10, 50_000].min
  begin
    # go through everything backwards so that nodes are created in hierarchical order -
    # du lists directories after their contents
    lines.reverse_each do |ll|
      count += 1
      
      # ignore small files
      unless(ll.to_i < $threshold)
        until ll =~ /^([0-9]+)\s+#{Regexp.escape(currentNode.fullName)}(\/.+)$/
          currentNode = currentNode.parent
          raise('Format error: '+ll) unless currentNode
        end
        currentNode = Node.new($2.strip, currentNode, $1.to_i)

        # throw out some output every once in a while to reassure our user we haven't fallen in a well
        puts(count.to_s + ' nodes created.') if(count % step == 0)
      end
    end
    
  rescue Exception => ee
    $stderr.puts('Error at node '+count.to_s+ "\n  "+lines[lines.length - count])
    raise ee
  end
end


#Okay, our data structures are built. Now for the hard/boring part, building an interface.

$rootNode.open = true

require 'curses'
Curses::init_screen
Curses::noecho

$mainWindow = Curses::stdscr.subwin(Curses::lines-2, Curses::cols, 0,0)
def initUI
  $resize = false
  Curses::close_screen
  Curses::init_screen
  
  Curses::stdscr.keypad(true)
  
  Curses::stdscr.refresh
  $mainWindow.resize(Curses::lines-2, Curses::cols)
  
  drawMainWindow
end

def drawMainWindow
  Curses::stdscr.setpos(Curses::lines-2, 1)
  Curses::stdscr.addstr('(Q)uit  (->) Expand  (<-) Contract/Move Up  (Up Dn PgUp PgDn) Scroll')
  Curses::stdscr.setpos(Curses::lines-1, 1)
  Curses::stdscr.addstr('(H)uman-readable     Sort: (S)ize  (N)ame     (T)reshold: '+ $threshold.to_s_commas)
  Curses::stdscr.clrtoeol
  
  1.upto($mainWindow.maxy-2) do |ii|
    $mainWindow.setpos(ii,1)
    $mainWindow.addstr($list[ii-1+$cursor].to_s($rootNode.size.to_sf.length)[0..($mainWindow.maxx-3)]) if(ii-1+$cursor < $list.length)
    $mainWindow.clrtoeol
  end

  Curses::stdscr.refresh
  $mainWindow.refresh
end


$resize = true
$quit = false
Signal.trap('WINCH') {$resize = true}

$list = $rootNode.list(nil, false, 1)

$cursor = 0
$sort = nil
$sortReverse = false
$threshold = 1
$humanReadable = false

until $quit
  initUI if $resize

  case Curses.getch
    when 'q', 'Q'
      $quit = true
    when Curses::KEY_UP
      $cursor = [$cursor-1,0].max
      drawMainWindow
      
    when Curses::KEY_DOWN
      $cursor = [$cursor+1,$list.length-1].min
      drawMainWindow
      
    when Curses::KEY_RIGHT
      unless($list[$cursor].children.empty? || $list[$cursor].open)
        $list[$cursor].open = true
        $list = $rootNode.list($sort, $sortReverse, $threshold)
        drawMainWindow
      end
      
    when Curses::KEY_LEFT
      if($list[$cursor].open)
        $list[$cursor].open = false
        $list = $rootNode.list($sort, $sortReverse, $threshold)
        drawMainWindow
      elsif($list[$cursor].parent)
        $cursor = $list.index($list[$cursor].parent)
        drawMainWindow
      end
      
    when Curses::KEY_NPAGE
      $cursor = [$cursor+$mainWindow.maxy-3,$list.length-1].min
      drawMainWindow
    when Curses::KEY_PPAGE
      $cursor = [$cursor-$mainWindow.maxy-3,0].max
      drawMainWindow
      
    when 's', 'S'
      $sortReverse = ($sort == :size ? !$sortReverse : true)
      $sort = :size
      $cursor = $list[$cursor]
      $list = $rootNode.list(:size, $sortReverse, $threshold)
      $cursor = $list.index($cursor)
      drawMainWindow
      
    when 'n', 'N'
      $sortReverse = ($sort == :name ? !$sortReverse : false)
      $sort = :name
      $cursor = $list[$cursor]
      $list = $rootNode.list(:name, $sortReverse, $threshold)
      $cursor = $list.index($cursor)
      drawMainWindow
      
    when 't', 'T'
      win = $mainWindow.subwin(3, $mainWindow.maxx - 4, 2, 2)
      win.clear
      win.box('|','-', ' ')
      win.setpos(1,1)
      win.addstr('Hide nodes with size less than: ')
      win.refresh
      Curses::echo
      $threshold = win.getstr.to_i
      Curses::noecho
      $list = $rootNode.list($sort, $sortReverse, $threshold)
      drawMainWindow

    when 'h', 'H'
      $humanReadable = !$humanReadable
      class Integer
        alias_method :to_sf, ($humanReadable ? :to_s_filesize : :to_s_commas)
      end
      drawMainWindow    
  end
  
end

Curses::close_screen
