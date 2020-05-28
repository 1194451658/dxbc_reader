

local DataDump = require 'table_dumper'

--  ----------------------
--      解析命令行
--  ----------------------

local argparse = require 'argparse'
local arg_parse = argparse('dxbc_reader')

arg_parse:argument('input', 'input file')
arg_parse:option('-o --output', 'output file', false)
arg_parse:option('-d --debug', 'print debug info', false)
arg_parse:option('-p --print', 'std print', true)

local args = arg_parse:parse()

if not args.input then
    args.input = 'fragment4.txt'
end
if not args.output then
    args.output = args.input .. '.hlsl'
end

if args.print == 'false' then
    args.print = false
end

local DEBUG=args.debug

--  -----------------------
--      dxcb的另外2个文件
--  -----------------------
local parser = require 'dxbc_parse'
local dxbc_def = require 'dxbc_def'

--local file_name = 'fragment.dxbc'
local file_name = args.input

local _format = string.format

-- 打开输入文件
local file = io.open(file_name, 'r')
local str = file:read('*a')

-- 语法解析
local parse_data = parser(str)

dxbc_def:init(parse_data)

--print(DataDump(parse_data))

-- op: 命令的字符串
-- 匹配所有命令的pattern, 看是哪个命令
-- command:
-- {
--   args={ { name="r0", suffix="y" }, { idx="6", name="cb0", suffix="w" } },
--   op="mov",
--   src="mov r0.y, cb0[6].w" 
-- },

-- 返回：匹配上的命令的pattern, 匹配上的命令的参数类型(例如：)
local function get_op(op)
    if not op then return end

    -- 匹配的命令pattern，找到的capture
    -- 被当作op_param
    local capture

    -- 匹配的命令的pattern，被当作op_name
    local target_op
    for op_def in  pairs(dxbc_def.shader_def) do
        -- lua，调用字符串的gsub
        -- op_def是，匹配命令的正则表达式
        if op:gsub(
            '^' .. op_def .. '$',
            function(...) 
                capture = {...} 
            end
            ) and
            capture then
            target_op = op_def
            break
        end
    end
    return target_op, capture
end

-- 就是把value，也当成了key
-- 可以判断一个value是否存在
local function arr2dic(list)
    local dic = {}
    for idx, v in pairs(list) do
        dic[v] = true
        dic[idx] = v
    end
    return dic
end

local BLOCK_DEF = {
    ['if'] = {
        start = 'if',
        close = {['else']=true, endif=true},
    },
    ['else'] = {
        start = 'else',
        close = {endif=true},
    },
    ['loop'] = {
        start = 'loop',
        close = {endloop=true},
    },
    ['switch'] = {
        start = 'switch',
        close = {endswitch=true},
    },
    ['case'] = {
        --[[
            case can closed by self
            switch a
                case a
                case b
                    break
            endswitch
        ]]--
        start = 'case',
        close = {case=true, ['break']=true},
    }
}

-- 把参数中的idx，能转换成nubmer，就转换成number
-- command: lpeg匹配到的命令
local function pre_process_command(command)
    -- 命令的参数
    if command.args then
        for _, reg in pairs(command.args) do

            -- 如果有[]里的内容
            -- 如果，可以转换成数字，则转换成数字
            if reg.idx then
                if tonumber(reg.idx) then
                    reg.idx = tonumber(reg.idx)
                end
            end
        end
    end
end

-- 翻译之后的代码
local translate = {}
local idx = 2
local line_id = 1
local blocks = {}

-- 注释里定义的内容
local res_def = parse_data[1]

-- 添加，翻译的一行
local function append(msg)
    translate[#translate+1] = msg
end

if DEBUG == 't' then
    append(DataDump(res_def.binding_data))
end

--
-- 开始代码生成
--

-- 生成cbuff
-- 根据dxbc注释里，定义的内容
-- 生成class, class INPUT, class OUT
--

------------  CBUFFER DEFINE
for _, cbuff in pairs(res_def.cbuff_data) do
    append('class ' .. cbuff.cbuffer_name .. '{')
    for _, var in pairs(cbuff.vars) do
        append(_format('\t%s\t%s;', var.type, var.name))
    end
    append('}')
end

-- 生成Input
local _tex_reg_cnt = 1
append('class INPUT {')
for _, var in pairs(res_def.input_data) do
    if var.name == 'TEXCOORD' then
        append('\t' .. var.name .. _tex_reg_cnt .. ';')
        _tex_reg_cnt = _tex_reg_cnt+1
    else
        append('\t' .. var.name.. ';')
    end
end
append('}')

-- 生成Out
_tex_reg_cnt=1
append('class OUT {')
for _, var in pairs(res_def.output_data) do
    if var.name == 'TEXCOORD' then
        append('\t' .. var.name .. _tex_reg_cnt.. ';')
        _tex_reg_cnt = _tex_reg_cnt+1
    else
        append('\t' .. var.name .. ';')
    end
end
append('}')
------------ CBUFFER DEFINE END

-- 生成，主函数
append("void main(INPUT in) {")
blocks[1] = {close = {}}

-- 遍历语法树
-- idx: 
--  * 从2开始
--  * 跳过开头的，注释里的内容
--  * 跳过开头的，例如：ps_5_0语句
while idx <= #parse_data do
    -- command: 
    --  * dxbc命令
    --  * 例如：
    -- {
    --   args={ { name="r0", suffix="y" }, { idx="6", name="cb0", suffix="w" } },
    --   op="mov",
    --   src="mov r0.y, cb0[6].w" 
    -- },
    local command = parse_data[idx]

    -- 如果是命令
    if command.op then
        -- op: 感觉像是字符串格式
        -- op_name: 匹配上的命令的pattern
        -- op_param: 命令后面的后缀，例如：mov_sat中的"_sat"
        local op_name, op_param = get_op(command.op)

        -- 有匹配到，是哪个命令
        if op_name then

            -- def.lua中定义的
            -- 命令对应的函数
            local op_func = dxbc_def.shader_def[op_name]
            if op_func then
                -- 把command参数中的idx，能转换成nubmer，就转换成number
                pre_process_command(command)

                -- 处理op_param，可以方便的判断，有没有_sat
                -- 例如命令： mov_sat r0.xy, v1.yxyy
                -- 就是把value，也当成了key
                -- 可以判断一个value是否存在
                op_param = op_param and arr2dic( op_param) or {}

                -- 进行语句的翻译
                -- op_str: 翻译之后的语句
                local op_str, block_tag = op_func(op_param, table.unpack(command.args))

                -- blocks: 
                --  * 标记{}的栈？
                --  * 用来判断，是第几层缩进
                local last_block = blocks[#blocks]
                if last_block and last_block.close[block_tag] then
                    table.remove(blocks, #blocks)
                end

                if DEBUG then
                    append('')
                    if DEBUG == 't' then
                        append(string.rep('\t', #blocks) .. DataDump(command))
                    end
                    append(string.rep('\t', #blocks) .. command.src)
                end

                -- 生成代码的，最后一个字符
                local last_gram = op_str:sub(#op_str)

                -- 判断，行末结束字符是什么
                local end_block = (last_gram == '}' or last_gram == '{' ) and '' or ';'

                -- 写入，生成的代码
                append(string.format('%s%s%s', string.rep('\t', #blocks), op_str, end_block))

                if BLOCK_DEF[block_tag] then
                    table.insert(blocks, BLOCK_DEF[block_tag])
                end
                line_id = line_id+1
            end
        else
            assert(false, 'not implement op ' .. command.op)
        end
    end
    idx = idx+1
end
append("}")

local ret = table.concat(translate, '\n')
if args.print then
    print(ret)
end

io.open(args.output, 'w'):write(ret)
