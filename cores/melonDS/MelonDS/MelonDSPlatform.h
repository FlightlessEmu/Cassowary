/*
    Copyright 2016-2025 melonDS team

    This file is part of melonDS.

    melonDS is free software: you can redistribute it and/or modify it under
    the terms of the GNU General Public License as published by the Free
    Software Foundation, either version 3 of the License, or (at your option)
    any later version.

    melonDS is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with melonDS. If not, see http://www.gnu.org/licenses/.
*/

#pragma once

#include <string>

#include "Platform.h"

namespace melonDS::Platform
{

/// The directory the core treats as "local" when it asks for a file by name
/// (firmware images, config files). The app points this at its support folder.
void SetLocalDirectory(const std::string& path);
const std::string& GetLocalDirectory();

/// Drop messages below this level. The default hides Debug and Info, which
/// the core emits on every ROM load and state change.
void SetLogLevel(LogLevel level);

} // namespace melonDS::Platform
